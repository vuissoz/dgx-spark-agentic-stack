#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_D_TESTS:-0}" == "1" ]]; then
  ok "D2 skipped because AGENTIC_SKIP_D_TESTS=1"
  exit 0
fi

toolbox_cid="$(require_service_container toolbox)"
gate_cid="$(require_service_container ollama-gate)"

wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${gate_cid}" 60 || fail "ollama-gate is not ready"

resp1_file="$(mktemp)"
resp2_file="$(mktemp)"
trap 'rm -f "${resp1_file}" "${resp2_file}"' EXIT

(
  timeout 25 docker exec "${toolbox_cid}" sh -lc "curl -sS -H 'Content-Type: application/json' -H 'X-Agent-Session: d2-long' -H 'X-Agent-Project: d2' -H 'X-Gate-Dry-Run: 1' -H 'X-Gate-Test-Sleep: 5' -d '{\"model\":\"d2-model-a\",\"messages\":[{\"role\":\"user\",\"content\":\"long request\"}]}' http://ollama-gate:11435/v1/chat/completions -w '\n%{http_code}'" \
    >"${resp1_file}"
) &
pid1=$!

sleep 0.4

(
  timeout 20 docker exec "${toolbox_cid}" sh -lc "curl -sS -H 'Content-Type: application/json' -H 'X-Agent-Session: d2-short' -H 'X-Agent-Project: d2' -H 'X-Gate-Dry-Run: 1' -H 'X-Gate-Queue-Timeout-Seconds: 1' -d '{\"model\":\"d2-model-b\",\"messages\":[{\"role\":\"user\",\"content\":\"short request\"}]}' http://ollama-gate:11435/v1/chat/completions -w '\n%{http_code}'" \
    >"${resp2_file}"
) &
pid2=$!

wait "${pid1}" || fail "first request failed to complete"
wait "${pid2}" || fail "second request failed to complete"

code1="$(tail -n 1 "${resp1_file}" | tr -d '\r')"
code2="$(tail -n 1 "${resp2_file}" | tr -d '\r')"
body1="$(sed '$d' "${resp1_file}")"
body2="$(sed '$d' "${resp2_file}")"

[[ "${code1}" == "200" ]] || {
  printf '%s\n' "${body1}" >&2
  fail "expected first request to pass with 200, got ${code1}"
}
ok "first long request passed"

if [[ "${code2}" == "200" ]]; then
  printf '%s\n' "${body2}" >&2
  fail "expected second concurrent request to be queued/denied, got 200"
fi
printf '%s\n' "${body2}" | grep -Eqi 'queue_timeout|denied|reason' \
  || fail "second request did not return an explicit queue/deny reason"
ok "second concurrent request is explicitly denied/queued"

gate_log="${AGENTIC_ROOT:-/srv/agentic}/gate/logs/gate.jsonl"
[[ -s "${gate_log}" ]] || fail "gate log file missing or empty: ${gate_log}"

tail -n 20 "${gate_log}" | grep -q '"session"' || fail "gate logs missing session field"
tail -n 20 "${gate_log}" | grep -q '"project"' || fail "gate logs missing project field"
tail -n 20 "${gate_log}" | grep -q '"decision"' || fail "gate logs missing decision field"
tail -n 20 "${gate_log}" | grep -q '"latency_ms"' || fail "gate logs missing latency field"
tail -n 20 "${gate_log}" | grep -q '"model_requested"' || fail "gate logs missing model_requested field"
tail -n 20 "${gate_log}" | grep -q '"model_served"' || fail "gate logs missing model_served field"
ok "gate logs contain required fields"

ok "D2_gate_concurrency passed"
