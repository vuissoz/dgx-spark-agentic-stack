#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_C_TESTS:-0}" == "1" ]]; then
  ok "C2 skipped because AGENTIC_SKIP_C_TESTS=1"
  exit 0
fi

ollama_cid="$(require_service_container ollama)"
wait_for_container_ready "${ollama_cid}" 180 || fail "ollama is not ready"

smoke_script="${REPO_ROOT}/deployments/ollama/smoke_generate.sh"
[[ -x "${smoke_script}" ]] || fail "missing executable smoke script: ${smoke_script}"

smoke_output="$(mktemp)"
trap 'rm -f "${smoke_output}"' EXIT

set +e
OLLAMA_API_URL="http://127.0.0.1:11434" \
  OLLAMA_SMOKE_TIMEOUT_SECONDS="${OLLAMA_SMOKE_TIMEOUT_SECONDS:-120}" \
  "${smoke_script}" >"${smoke_output}" 2>&1
smoke_rc=$?
set -e

if [[ "${smoke_rc}" -ne 0 ]]; then
  cat "${smoke_output}" >&2
  fail "ollama generate smoke script failed"
fi

if grep -q '^SKIP:' "${smoke_output}"; then
  ok "C2 skipped generate probe because no local model is available"
else
  grep -q '^OK: ollama generate smoke passed' "${smoke_output}" \
    || fail "smoke script succeeded but did not report generate success"
  ok "ollama generate endpoint returned HTTP 200 with non-empty payload"
fi

log_tail="$(docker logs --tail 80 "${ollama_cid}" 2>&1 || true)"
[[ -n "${log_tail}" ]] || fail "ollama logs are empty"
ok "ollama logs are present"

ok "C2_ollama_generate passed"
