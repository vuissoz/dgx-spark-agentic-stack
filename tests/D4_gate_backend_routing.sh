#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_D_TESTS:-0}" == "1" ]]; then
  ok "D4 skipped because AGENTIC_SKIP_D_TESTS=1"
  exit 0
fi

assert_cmd python3

toolbox_cid="$(require_service_container toolbox)"
gate_cid="$(require_service_container ollama-gate)"
trt_cid="$(service_container_id trtllm)"

if [[ -z "${trt_cid}" ]]; then
  ok "D4 skipped because trtllm profile is not enabled (set COMPOSE_PROFILES=trt)"
  exit 0
fi

cleanup() {
  if [[ -n "${trt_cid}" ]]; then
    current_state="$(docker inspect --format '{{.State.Status}}' "${trt_cid}" 2>/dev/null || true)"
    if [[ "${current_state}" != "running" ]]; then
      docker start "${trt_cid}" >/dev/null 2>&1 || true
      wait_for_container_ready "${trt_cid}" 120 || true
    fi
  fi
}
trap cleanup EXIT

wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${gate_cid}" 90 || fail "ollama-gate is not ready"
wait_for_container_ready "${trt_cid}" 120 || fail "trtllm is not ready"

gate_log="${AGENTIC_ROOT:-/srv/agentic}/gate/logs/gate.jsonl"
[[ -e "${gate_log}" ]] || fail "gate log file missing: ${gate_log}"

call_chat() {
  local session="$1"
  local model="$2"
  local dry_run="$3"
  local dry_header=""
  if [[ "${dry_run}" == "1" ]]; then
    dry_header="-H 'X-Gate-Dry-Run: 1'"
  fi

  timeout 25 docker exec "${toolbox_cid}" sh -lc "curl -sS -H 'Content-Type: application/json' -H 'X-Agent-Session: ${session}' -H 'X-Agent-Project: d4' ${dry_header} -d '{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"backend routing check\"}]}' http://ollama-gate:11435/v1/chat/completions -w '\n%{http_code}'"
}

extract_code() {
  printf '%s\n' "$1" | tail -n 1 | tr -d '\r'
}

extract_body() {
  printf '%s\n' "$1" | sed '$d'
}

assert_log_backend() {
  local session="$1"
  local expected_backend="$2"
  local line

  line="$(grep "\"session\":\"${session}\"" "${gate_log}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || fail "no gate log entry found for session ${session}"
  printf '%s\n' "${line}" | grep -q "\"backend\":\"${expected_backend}\"" \
    || fail "unexpected backend for session ${session} (expected=${expected_backend}, line=${line})"
}

session_ollama="d4-ollama-$$"
resp_ollama="$(call_chat "${session_ollama}" "qwen3:0.6b" 1)"
code_ollama="$(extract_code "${resp_ollama}")"
[[ "${code_ollama}" == "200" ]] || fail "standard model dry-run request failed with status ${code_ollama}"
assert_log_backend "${session_ollama}" "ollama"
ok "standard model is routed to backend=ollama"

session_trt="d4-trt-$$"
resp_trt="$(call_chat "${session_trt}" "qwen3-nvfp4-demo" 0)"
code_trt="$(extract_code "${resp_trt}")"
body_trt="$(extract_body "${resp_trt}")"
[[ "${code_trt}" == "200" ]] || {
  printf '%s\n' "${body_trt}" >&2
  fail "NVFP4 model routed request failed with status ${code_trt} while trtllm is healthy"
}
assert_log_backend "${session_trt}" "trtllm"
ok "NVFP4 model is routed to backend=trtllm"

docker stop "${trt_cid}" >/dev/null

session_unavailable="d4-trt-down-$$"
resp_unavailable="$(call_chat "${session_unavailable}" "qwen3-nvfp4-demo" 0)"
code_unavailable="$(extract_code "${resp_unavailable}")"
body_unavailable="$(extract_body "${resp_unavailable}")"
[[ "${code_unavailable}" == "503" ]] || {
  printf '%s\n' "${body_unavailable}" >&2
  fail "expected 503 when trtllm backend is unavailable (actual=${code_unavailable})"
}
printf '%s\n' "${body_unavailable}" | grep -q '"type":"backend_unavailable"' \
  || fail "missing backend_unavailable error type when trtllm is down"
printf '%s\n' "${body_unavailable}" | grep -q '"backend":"trtllm"' \
  || fail "missing backend=trtllm in unavailable error payload"
assert_log_backend "${session_unavailable}" "trtllm"
ok "routed NVFP4 request fails explicitly and actionably when trtllm is unavailable"

docker start "${trt_cid}" >/dev/null
wait_for_container_ready "${trt_cid}" 120 || fail "trtllm did not recover after restart"

ok "D4_gate_backend_routing passed"
