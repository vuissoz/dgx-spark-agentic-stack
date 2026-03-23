#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

resolver="${REPO_ROOT}/deployments/releases/resolve_latest.py"
[[ -f "${resolver}" ]] || fail "resolver script is missing"

tmpdir="$(mktemp -d)"
bindir="${tmpdir}/bin"
outdir="${tmpdir}/out"
mkdir -p "${bindir}" "${outdir}"

cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

cat >"${bindir}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "compose" ]]; then
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-name|-f)
        shift 2
        ;;
      config)
        shift
        if [[ "${1:-}" == "--format" && "${2:-}" == "json" ]]; then
          cat <<'JSON'
{
  "services": {
    "agentic-codex": {
      "build": {
        "args": {
          "CODEX_CLI_NPM_SPEC": "@openai/codex@latest",
          "CLAUDE_CODE_NPM_SPEC": "@anthropic-ai/claude-code@latest",
          "OPENCODE_NPM_SPEC": "opencode-ai@latest",
          "PI_CODING_AGENT_NPM_SPEC": "@mariozechner/pi-coding-agent@latest",
          "OPENCLAW_INSTALL_VERSION": "latest"
        }
      },
      "image": "agentic/agent-cli-base:local"
    },
    "ollama": {
      "image": "ollama/ollama:latest"
    },
    "openwebui": {
      "image": "ghcr.io/open-webui/open-webui:latest"
    }
  }
}
JSON
          exit 0
        fi
        ;;
    esac
  done
fi

if [[ "${1:-}" == "pull" ]]; then
  exit 0
fi

if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  image_ref="${5:-}"
  case "${image_ref}" in
    ollama/ollama:latest)
      printf '%s\n' '["ollama/ollama@sha256:1111111111111111111111111111111111111111111111111111111111111111"]'
      ;;
    ghcr.io/open-webui/open-webui:latest)
      printf '%s\n' '["ghcr.io/open-webui/open-webui@sha256:2222222222222222222222222222222222222222222222222222222222222222"]'
      ;;
    *)
      printf '%s\n' '[]'
      ;;
  esac
  exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 1
EOF

cat >"${bindir}/python3" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/python3 "$@"
EOF

chmod 0755 "${bindir}/docker" "${bindir}/python3"

export PATH="${bindir}:${PATH}"
export AGENTIC_CODEX_CLI_NPM_SPEC='@openai/codex@latest'
export AGENTIC_CLAUDE_CODE_NPM_SPEC='@anthropic-ai/claude-code@latest'
export AGENTIC_OPENCODE_NPM_SPEC='opencode-ai@latest'
export AGENTIC_PI_CODING_AGENT_NPM_SPEC='@mariozechner/pi-coding-agent@latest'
export AGENTIC_OPENCLAW_INSTALL_VERSION='latest'

PYTHONPATH= \
python3 - <<'PY' "${resolver}" "${outdir}"
import json
import pathlib
import sys
import urllib.request

resolver = pathlib.Path(sys.argv[1])
outdir = pathlib.Path(sys.argv[2])

registry_payloads = {
    "https://registry.npmjs.org/%40openai%2Fcodex": {"dist-tags": {"latest": "0.116.0"}},
    "https://registry.npmjs.org/%40anthropic-ai%2Fclaude-code": {"dist-tags": {"latest": "2.1.81"}},
    "https://registry.npmjs.org/opencode-ai": {"dist-tags": {"latest": "1.3.0"}},
    "https://registry.npmjs.org/%40mariozechner%2Fpi-coding-agent": {"dist-tags": {"latest": "0.62.0"}},
    "https://registry.npmjs.org/openclaw": {"dist-tags": {"latest": "2026.3.22"}},
}


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def read(self):
        return json.dumps(self.payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


def fake_urlopen(url, timeout=20):
    if url not in registry_payloads:
        raise RuntimeError(f"unexpected url: {url}")
    return FakeResponse(registry_payloads[url])


urllib.request.urlopen = fake_urlopen
globals_dict = {"__name__": "__main__", "__file__": str(resolver)}
code = compile(resolver.read_text(encoding="utf-8"), str(resolver), "exec")
sys.argv = [str(resolver), "--project-name", "agentic-test", "--output-dir", str(outdir), "-f", "compose.core.yml"]
exec(code, globals_dict)
PY

[[ -s "${outdir}/runtime.resolved.env" ]] || fail "runtime.resolved.env should be generated"
[[ -s "${outdir}/compose.resolved.override.yml" ]] || fail "compose.resolved.override.yml should be generated"
[[ -s "${outdir}/latest-resolution.json" ]] || fail "latest-resolution.json should be generated"

grep -q '^AGENTIC_CODEX_CLI_NPM_SPEC=@openai/codex@0.116.0$' "${outdir}/runtime.resolved.env" \
  || fail "codex latest spec was not resolved deterministically"
grep -q '^AGENTIC_OPENCLAW_INSTALL_VERSION=2026.3.22$' "${outdir}/runtime.resolved.env" \
  || fail "openclaw latest version was not resolved deterministically"
grep -q 'ollama/ollama@sha256:1111111111111111111111111111111111111111111111111111111111111111' "${outdir}/compose.resolved.override.yml" \
  || fail "ollama latest image was not pinned in compose override"
grep -q 'ghcr.io/open-webui/open-webui@sha256:2222222222222222222222222222222222222222222222222222222222222222' "${outdir}/compose.resolved.override.yml" \
  || fail "openwebui latest image was not pinned in compose override"
grep -q '"requested": "@openai/codex@latest"' "${outdir}/latest-resolution.json" \
  || fail "resolution manifest must keep the requested latest value"
grep -q '"resolved": "@openai/codex@0.116.0"' "${outdir}/latest-resolution.json" \
  || fail "resolution manifest must keep the resolved codex version"

ok "F11_latest_resolution passed"
