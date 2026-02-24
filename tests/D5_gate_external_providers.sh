#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_D_TESTS:-0}" == "1" ]]; then
  ok "D5 skipped because AGENTIC_SKIP_D_TESTS=1"
  exit 0
fi

case "${AGENTIC_SKIP_D5_TESTS:-0}" in
  1|true|TRUE|yes|YES|on|ON)
    warn "D5 skipped because AGENTIC_SKIP_D5_TESTS=1 (no external API access mode)"
    exit 0
    ;;
esac

assert_cmd python3

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
model_routes_file="${agentic_root}/gate/config/model_routes.yml"
gate_log="${agentic_root}/gate/logs/gate.jsonl"
proxy_log="${agentic_root}/proxy/logs/access.log"
openai_key_file="${agentic_root}/secrets/runtime/openai.api_key"
openrouter_key_file="${agentic_root}/secrets/runtime/openrouter.api_key"
openai_model="${D5_OPENAI_MODEL:-gpt-4o-mini}"
openrouter_model="${D5_OPENROUTER_MODEL:-openai/gpt-4o-mini}"

[[ -f "${model_routes_file}" ]] || fail "model routes file missing: ${model_routes_file}"

toolbox_cid="$(require_service_container toolbox)"
gate_cid="$(require_service_container ollama-gate)"

wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${gate_cid}" 90 || fail "ollama-gate is not ready"

backup_file="$(mktemp)"
cp "${model_routes_file}" "${backup_file}"

restore_routes() {
  if [[ -f "${backup_file}" ]]; then
    cp "${backup_file}" "${model_routes_file}" || true
    chmod 0640 "${model_routes_file}" || true
  fi
  rm -f "${backup_file}" || true
  if [[ -n "${gate_cid:-}" ]]; then
    docker restart "${gate_cid}" >/dev/null 2>&1 || true
    wait_for_container_ready "${gate_cid}" 120 || true
  fi
}
trap restore_routes EXIT

cat >"${model_routes_file}" <<YAML
version: 1

defaults:
  backend: ollama

backends:
  ollama:
    protocol: ollama
    base_url: http://ollama:11434
  trtllm:
    protocol: ollama
    base_url: http://trtllm:11436
  openai:
    protocol: openai
    provider: openai
    base_url: https://api.openai.com/v1
    api_key_file: /gate/secrets/openai.api_key
  openrouter:
    protocol: openai
    provider: openrouter
    base_url: https://openrouter.ai/api/v1
    api_key_file: /gate/secrets/openrouter.api_key
  openai-missing:
    protocol: openai
    provider: openai
    base_url: https://api.openai.com/v1
    api_key_file: /gate/secrets/does-not-exist.api_key

routes:
  - name: d5-missing-key
    backend: openai-missing
    match:
      - "d5-missing-*"
  - name: d5-openai
    backend: openai
    match:
      - "${openai_model}"
  - name: d5-openrouter
    backend: openrouter
    match:
      - "${openrouter_model}"
  - name: nvfp4-to-trtllm
    backend: trtllm
    match:
      - "*nvfp4*"
      - "trtllm/*"
      - "trt-*"
YAML
chmod 0640 "${model_routes_file}" || true

docker restart "${gate_cid}" >/dev/null
wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate did not become healthy after D5 route reload"

call_chat() {
  local session="$1"
  local model="$2"
  timeout 45 docker exec "${toolbox_cid}" sh -lc "curl -sS -H 'Content-Type: application/json' -H 'X-Agent-Session: ${session}' -H 'X-Agent-Project: d5' -d '{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"d5 provider check\"}]}' http://ollama-gate:11435/v1/chat/completions -w '\n%{http_code}'"
}

extract_code() {
  printf '%s\n' "$1" | tail -n 1 | tr -d '\r'
}

extract_body() {
  printf '%s\n' "$1" | sed '$d'
}

assert_log_provider() {
  local session="$1"
  local expected_backend="$2"
  local expected_provider="$3"
  local line

  line="$(grep "\"session\":\"${session}\"" "${gate_log}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || fail "no gate log entry found for session ${session}"
  printf '%s\n' "${line}" | grep -q "\"backend\":\"${expected_backend}\"" \
    || fail "unexpected backend for session ${session}: ${line}"
  printf '%s\n' "${line}" | grep -q "\"provider\":\"${expected_provider}\"" \
    || fail "unexpected provider for session ${session}: ${line}"
}

missing_session="d5-missing-$$"
missing_resp="$(call_chat "${missing_session}" "d5-missing-model")"
missing_code="$(extract_code "${missing_resp}")"
missing_body="$(extract_body "${missing_resp}")"
[[ "${missing_code}" == "503" ]] || {
  printf '%s\n' "${missing_body}" >&2
  fail "missing-key provider route must fail explicitly with 503 (actual=${missing_code})"
}
printf '%s\n' "${missing_body}" | grep -q '"type":"backend_auth_error"' \
  || fail "missing-key failure must expose backend_auth_error"
printf '%s\n' "${missing_body}" | grep -q 'does-not-exist.api_key' \
  || fail "missing-key failure must be actionable and point to API key file"
assert_log_provider "${missing_session}" "openai-missing" "openai"
ok "missing provider API key is rejected explicitly and actionably"

if [[ "${AGENTIC_ENABLE_EXTERNAL_PROVIDER_TESTS:-0}" != "1" ]]; then
  ok "D5 external live calls skipped (set AGENTIC_ENABLE_EXTERNAL_PROVIDER_TESTS=1 to validate OpenAI/OpenRouter upstream calls)"
  ok "D5_gate_external_providers passed (baseline checks)"
  exit 0
fi

[[ -s "${openai_key_file}" ]] || fail "missing OpenAI API key file: ${openai_key_file}"
[[ -s "${openrouter_key_file}" ]] || fail "missing OpenRouter API key file: ${openrouter_key_file}"

openai_session="d5-openai-$$"
openai_resp="$(call_chat "${openai_session}" "${openai_model}")"
openai_code="$(extract_code "${openai_resp}")"
openai_body="$(extract_body "${openai_resp}")"
[[ "${openai_code}" == "200" ]] || {
  printf '%s\n' "${openai_body}" >&2
  fail "OpenAI routed request failed with status ${openai_code}"
}
printf '%s\n' "${openai_body}" | grep -q '"choices"' || fail "OpenAI response is not usable"
assert_log_provider "${openai_session}" "openai" "openai"
ok "openai backend routing is functional"

openrouter_session="d5-openrouter-$$"
openrouter_resp="$(call_chat "${openrouter_session}" "${openrouter_model}")"
openrouter_code="$(extract_code "${openrouter_resp}")"
openrouter_body="$(extract_body "${openrouter_resp}")"
[[ "${openrouter_code}" == "200" ]] || {
  printf '%s\n' "${openrouter_body}" >&2
  fail "OpenRouter routed request failed with status ${openrouter_code}"
}
printf '%s\n' "${openrouter_body}" | grep -q '"choices"' || fail "OpenRouter response is not usable"
assert_log_provider "${openrouter_session}" "openrouter" "openrouter"
ok "openrouter backend routing is functional"

[[ -s "${proxy_log}" ]] || fail "proxy log file missing or empty: ${proxy_log}"
sleep 2

grep -q 'api.openai.com' "${proxy_log}" \
  || fail "proxy log does not show OpenAI egress (expected api.openai.com)"
grep -q 'openrouter.ai' "${proxy_log}" \
  || fail "proxy log does not show OpenRouter egress (expected openrouter.ai)"
ok "provider calls are visible through egress proxy logs"

if [[ -s "${openai_key_file}" ]]; then
  openai_key="$(tr -d '\r\n' < "${openai_key_file}")"
  if [[ -n "${openai_key}" ]]; then
    grep -Fq "${openai_key}" "${gate_log}" && fail "OpenAI key leaked into gate logs"
    grep -Fq "${openai_key}" "${proxy_log}" && fail "OpenAI key leaked into proxy logs"
  fi
fi

if [[ -s "${openrouter_key_file}" ]]; then
  openrouter_key="$(tr -d '\r\n' < "${openrouter_key_file}")"
  if [[ -n "${openrouter_key}" ]]; then
    grep -Fq "${openrouter_key}" "${gate_log}" && fail "OpenRouter key leaked into gate logs"
    grep -Fq "${openrouter_key}" "${proxy_log}" && fail "OpenRouter key leaked into proxy logs"
  fi
fi
ok "provider secrets are not present in gate/proxy logs"

ok "D5_gate_external_providers passed"
