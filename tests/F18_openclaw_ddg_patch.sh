#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

fixture_dir="${tmpdir}/runtime"
mkdir -p "${fixture_dir}"
fixture_file="${fixture_dir}/ddg-client-fixture.js"

cat >"${fixture_file}" <<'EOF'
const DDG_HTML_ENDPOINT = "https://html.duckduckgo.com/html";
const url = new URL(DDG_HTML_ENDPOINT);
	url.searchParams.set("q", params.query);
	if (region) url.searchParams.set("kl", region);
	url.searchParams.set("kp", DDG_SAFE_SEARCH_PARAM[safeSearch]);
const results = await withTrustedWebSearchEndpoint({
		url: url.toString(),
		timeoutSeconds,
		init: {
			method: "GET",
			headers: { "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36" }
		}
}, async (response) => {});
EOF

python3 "${REPO_ROOT}/deployments/optional/patch_openclaw_ddg.py" --require-match "${fixture_dir}" >/tmp/f18-ddg-patch.out

grep -q 'const DDG_HTML_ENDPOINT = "https://html.duckduckgo.com/html/";' "${fixture_file}" \
  || { echo "patch must normalize the DuckDuckGo endpoint with trailing slash" >&2; exit 1; }
grep -q 'const body = new URLSearchParams();' "${fixture_file}" \
  || { echo "patch must replace URLSearchParams setup" >&2; exit 1; }
grep -q 'body.set("kl", region ?? "us-en");' "${fixture_file}" \
  || { echo "patch must force a stable fallback region for POST search" >&2; exit 1; }
grep -q 'method: "POST"' "${fixture_file}" \
  || { echo "patch must switch the DDG request to POST" >&2; exit 1; }
grep -q 'Content-Type": "application/x-www-form-urlencoded"' "${fixture_file}" \
  || { echo "patch must add form-urlencoded content type" >&2; exit 1; }
grep -q 'body: body.toString()' "${fixture_file}" \
  || { echo "patch must send the search body payload" >&2; exit 1; }

echo "OK: OpenClaw DDG patch rewrites GET html search to POST form submission"
