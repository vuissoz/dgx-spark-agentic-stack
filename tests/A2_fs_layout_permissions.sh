#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

BOOTSTRAP_SCRIPT="${REPO_ROOT}/deployments/bootstrap/init_fs.sh"
[[ -x "${BOOTSTRAP_SCRIPT}" ]] || fail "bootstrap script is missing or not executable: ${BOOTSTRAP_SCRIPT}"

AGENTIC_PROFILE="${AGENTIC_PROFILE:-strict-prod}"
if [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]]; then
  AGENTIC_ROOT="${AGENTIC_ROOT:-${HOME}/.local/share/agentic}"
else
  AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
fi

"${BOOTSTRAP_SCRIPT}"
"${BOOTSTRAP_SCRIPT}"
ok "bootstrap is idempotent"

required_dirs=(
  "${AGENTIC_ROOT}/deployments"
  "${AGENTIC_ROOT}/deployments/releases"
  "${AGENTIC_ROOT}/deployments/current"
  "${AGENTIC_ROOT}/bin"
  "${AGENTIC_ROOT}/tests"
  "${AGENTIC_ROOT}/secrets"
  "${AGENTIC_ROOT}/ollama"
  "${AGENTIC_ROOT}/gate"
  "${AGENTIC_ROOT}/gate/state"
  "${AGENTIC_ROOT}/gate/logs"
  "${AGENTIC_ROOT}/proxy"
  "${AGENTIC_ROOT}/dns"
  "${AGENTIC_ROOT}/openwebui"
  "${AGENTIC_ROOT}/openhands"
  "${AGENTIC_ROOT}/comfyui"
  "${AGENTIC_ROOT}/comfyui/models"
  "${AGENTIC_ROOT}/comfyui/input"
  "${AGENTIC_ROOT}/comfyui/output"
  "${AGENTIC_ROOT}/comfyui/user"
  "${AGENTIC_ROOT}/rag"
  "${AGENTIC_ROOT}/rag/qdrant"
  "${AGENTIC_ROOT}/rag/docs"
  "${AGENTIC_ROOT}/rag/scripts"
  "${AGENTIC_ROOT}/claude/state"
  "${AGENTIC_ROOT}/claude/logs"
  "${AGENTIC_ROOT}/claude/workspaces"
  "${AGENTIC_ROOT}/codex/state"
  "${AGENTIC_ROOT}/codex/logs"
  "${AGENTIC_ROOT}/codex/workspaces"
  "${AGENTIC_ROOT}/opencode/state"
  "${AGENTIC_ROOT}/opencode/logs"
  "${AGENTIC_ROOT}/opencode/workspaces"
  "${AGENTIC_ROOT}/shared-ro"
  "${AGENTIC_ROOT}/shared-rw"
)

for dir in "${required_dirs[@]}"; do
  [[ -d "${dir}" ]] || fail "missing required directory: ${dir}"
done
ok "required directory layout exists"

if find "${AGENTIC_ROOT}" -maxdepth 2 -type d -perm -0002 | grep -q '.'; then
  find "${AGENTIC_ROOT}" -maxdepth 2 -type d -perm -0002 >&2
  fail "world-writable directories detected under ${AGENTIC_ROOT}"
fi
ok "no world-writable directories in top-level layout"

secrets_mode="$(stat -c '%a' "${AGENTIC_ROOT}/secrets")"
case "${secrets_mode}" in
  700|710|750)
    ;;
  *)
    fail "invalid permissions for ${AGENTIC_ROOT}/secrets: ${secrets_mode} (expected 700/710/750)"
    ;;
esac

if [[ "${secrets_mode: -1}" != "0" ]]; then
  fail "others permissions must be 0 for ${AGENTIC_ROOT}/secrets (got ${secrets_mode})"
fi
ok "secrets directory excludes others"

while IFS= read -r secret_file; do
  mode="$(stat -c '%a' "${secret_file}")"
  case "${mode}" in
    600|640)
      ;;
    *)
      fail "secret file has unsafe mode ${mode}: ${secret_file}"
      ;;
  esac
done < <(find "${AGENTIC_ROOT}/secrets" -maxdepth 1 -type f)
ok "secret file permissions are constrained"

ok "A2_fs_layout_permissions passed"
