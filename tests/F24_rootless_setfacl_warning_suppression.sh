#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F24 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

init_script="${REPO_ROOT}/deployments/core/init_runtime.sh"
[[ -f "${init_script}" ]] || fail "core init script missing: ${init_script}"

tmp_dir="$(mktemp -d)"
fake_bin="${tmp_dir}/bin"
runtime_root="${tmp_dir}/runtime"
mkdir -p "${fake_bin}" "${runtime_root}/proxy/logs"

cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

cat >"${fake_bin}/setfacl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target="${@: -1}"
case "${target}" in
  */proxy/logs/access.log|*/proxy/logs/cache.log)
    echo "setfacl: ${target}: Operation not permitted" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${fake_bin}/setfacl"

touch "${runtime_root}/proxy/logs/access.log" "${runtime_root}/proxy/logs/cache.log"

set +e
output="$(
  PATH="${fake_bin}:$PATH" \
  AGENTIC_PROFILE=rootless-dev \
  AGENTIC_ROOT="${runtime_root}" \
  AGENTIC_OPENCLAW_WORKSPACES_DIR="${runtime_root}/openclaw/workspaces" \
  AGENT_RUNTIME_UID="$(id -u)" \
  AGENT_RUNTIME_GID="$(id -g)" \
  bash "${init_script}" 2>&1
)"
rc=$?
set -e

[[ "${rc}" -eq 0 ]] || {
  printf '%s\n' "${output}" >&2
  fail "core init should keep running when only file-level squid log ACL updates fail in rootless-dev"
}

printf '%s\n' "${output}" | grep -q 'non-root runtime init: unable to update file ACLs for squid logs under' \
  || fail "core init must emit a single explicit non-blocking file ACL warning"

if printf '%s\n' "${output}" | grep -q '^setfacl: .*Operation not permitted$'; then
  fail "core init must suppress raw setfacl Operation not permitted lines for the known non-blocking squid log case"
fi

printf '%s\n' "${output}" | grep -q 'non-root runtime init: applied ACL grants (uid 0 + uid 13)' \
  || fail "core init must still report the successful directory-level ACL grant path"

ok "F24_rootless_setfacl_warning_suppression passed"
