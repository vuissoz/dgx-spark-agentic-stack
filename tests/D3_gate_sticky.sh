#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_D_TESTS:-0}" == "1" ]]; then
  ok "D3 skipped because AGENTIC_SKIP_D_TESTS=1"
  exit 0
fi

assert_cmd python3

toolbox_cid="$(require_service_container toolbox)"
gate_cid="$(require_service_container ollama-gate)"

wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${gate_cid}" 60 || fail "ollama-gate is not ready"

call_chat() {
  local session="$1"
  local model="$2"
  timeout 20 docker exec "${toolbox_cid}" sh -lc "curl -sS -H 'Content-Type: application/json' -H 'X-Agent-Session: ${session}' -H 'X-Agent-Project: d3' -H 'X-Gate-Dry-Run: 1' -d '{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"sticky check\"}]}' http://ollama-gate:11435/v1/chat/completions -w '\n%{http_code}'"
}

extract_code() {
  printf '%s\n' "$1" | tail -n 1 | tr -d '\r'
}

extract_body() {
  printf '%s\n' "$1" | sed '$d'
}

extract_model() {
  printf '%s\n' "$1" | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("model",""))'
}

session="d3-session-$$"

resp1="$(call_chat "${session}" "sticky-model-a")"
resp2="$(call_chat "${session}" "sticky-model-a")"
resp3="$(call_chat "${session}" "sticky-model-b")"

code1="$(extract_code "${resp1}")"
code2="$(extract_code "${resp2}")"
code3="$(extract_code "${resp3}")"

body1="$(extract_body "${resp1}")"
body2="$(extract_body "${resp2}")"
body3="$(extract_body "${resp3}")"

[[ "${code1}" == "200" && "${code2}" == "200" && "${code3}" == "200" ]] || fail "initial sticky requests must all return 200"

served1="$(extract_model "${body1}")"
served2="$(extract_model "${body2}")"
served3="$(extract_model "${body3}")"

[[ -n "${served1}" ]] || fail "first served model is empty"
[[ "${served1}" == "${served2}" ]] || fail "sticky model drifted between first and second request"
[[ "${served3}" == "sticky-model-b" ]] || fail "explicit OpenAI-compatible model must update sticky session without X-Model-Switch (got ${served3})"
ok "explicit OpenAI-compatible model request updates sticky session"

switch_resp="$(timeout 15 docker exec "${toolbox_cid}" sh -lc "curl -sS -H 'Content-Type: application/json' -H 'X-Agent-Project: d3' -d '{\"model\":\"sticky-model-c\"}' http://ollama-gate:11435/admin/sessions/${session}/switch -w '\n%{http_code}'")"
switch_code="$(extract_code "${switch_resp}")"
switch_body="$(extract_body "${switch_resp}")"
[[ "${switch_code}" == "200" ]] || {
  printf '%s\n' "${switch_body}" >&2
  fail "explicit model switch failed"
}
ok "explicit switch endpoint accepted model change"

resp4="$(call_chat "${session}" "sticky-model-c")"
code4="$(extract_code "${resp4}")"
body4="$(extract_body "${resp4}")"
[[ "${code4}" == "200" ]] || fail "post-switch request failed"
served4="$(extract_model "${body4}")"
[[ "${served4}" == "sticky-model-c" ]] || fail "post-switch model mismatch (expected sticky-model-c, got ${served4})"
ok "explicit model switch is applied"

gate_log="${AGENTIC_ROOT:-/srv/agentic}/gate/logs/gate.jsonl"
[[ -s "${gate_log}" ]] || fail "gate log file missing or empty: ${gate_log}"
tail -n 40 "${gate_log}" | grep -q '"model_switch":true' \
  || fail "gate logs do not contain model_switch=true after model changes"
ok "gate logs include model_switch:true"

ok "D3_gate_sticky passed"
