#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

assert_cmd docker
assert_cmd python3

workflow="${REPO_ROOT}/examples/optional/n8n-workflows/doctor-n8n-local-ollama-validation.json"
runner="${REPO_ROOT}/scripts/n8n_doctor.py"
[[ -x "${runner}" ]] || fail "n8n doctor runner is missing or not executable"

python3 "${runner}" --workflow "${workflow}" --validate-template \
  || fail "n8n doctor workflow template is invalid"

valid_output="$(mktemp)"
invalid_output="$(mktemp)"
trap 'rm -f "${valid_output}" "${invalid_output}"' EXIT

printf '%s\n' '{"success":true,"doctor_status":"PASS","test_id":"N8N-DOCTOR-OLLAMA-001","n8n_execution":"OK","javascript_runtime":"OK","ollama_connection":"OK","qwen_inference":"OK","json_parsing":"OK","response_validation":"OK","backend":"ollama","model":"qwen3.8:27b"}' >"${valid_output}"
python3 "${runner}" --workflow "${workflow}" --validate-output-file "${valid_output}" \
  || fail "n8n doctor runner rejected the exact PASS contract"

printf '%s\n' '{"success":true,"doctor_status":"PASS","model":"wrong"}' >"${invalid_output}"
if python3 "${runner}" --workflow "${workflow}" --validate-output-file "${invalid_output}" >/dev/null 2>&1; then
  fail "n8n doctor runner accepted an invalid PASS contract"
fi

n8n_cid="$(require_service_container optional-n8n)" || exit 1
wait_for_container_ready "${n8n_cid}" 120 || fail "optional-n8n is not healthy"

python3 "${runner}" --workflow "${workflow}" --container "${n8n_cid}" --install \
  || fail "n8n doctor workflow installation failed"
python3 "${runner}" --workflow "${workflow}" --container "${n8n_cid}" --timeout-seconds 300 \
  || fail "n8n doctor workflow end-to-end validation failed"

ok "K22_n8n_doctor passed"
