#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_D_TESTS:-0}" == "1" ]]; then
  ok "D11 skipped because AGENTIC_SKIP_D_TESTS=1"
  exit 0
fi

assert_cmd python3

toolbox_cid="$(require_service_container toolbox)"
gate_cid="$(require_service_container ollama-gate)"
trt_cid="$(service_container_id trtllm)"

if [[ -z "${trt_cid}" ]]; then
  ok "D11 skipped because trtllm profile is not enabled (set COMPOSE_PROFILES=trt)"
  exit 0
fi

wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${gate_cid}" 90 || fail "ollama-gate is not ready"
wait_for_container_ready "${trt_cid}" 120 || fail "trtllm is not ready"

gate_log="${AGENTIC_ROOT:-/srv/agentic}/gate/logs/gate.jsonl"
[[ -e "${gate_log}" ]] || fail "gate log file missing: ${gate_log}"

chat_session="d11-chat-$$"
responses_session="d11-responses-$$"

chat_output="$(timeout 30 docker exec -i "${toolbox_cid}" python3 - "${chat_session}" <<'PY'
import json
import sys
import urllib.request

session = sys.argv[1]
payload = {
    "model": "trtllm/nemotron-cascade-2:30b",
    "messages": [
        {"role": "user", "content": "Use the read_file tool once for /workspace/README.md and stop."}
    ],
    "tools": [
        {
            "type": "function",
            "function": {
                "name": "read_file",
                "description": "Read a file",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                },
            },
        }
    ],
    "tool_choice": {"type": "function", "function": {"name": "read_file"}},
}
request = urllib.request.Request(
    "http://ollama-gate:11435/v1/chat/completions",
    data=json.dumps(payload).encode("utf-8"),
    headers={
        "Content-Type": "application/json",
        "X-Agent-Project": "d11",
        "X-Agent-Session": session,
    },
    method="POST",
)
with urllib.request.urlopen(request, timeout=25) as response:
    body = json.loads(response.read().decode("utf-8"))
tool_calls = body["choices"][0]["message"].get("tool_calls")
if not isinstance(tool_calls, list) or len(tool_calls) != 1:
    raise SystemExit(f"expected one tool call, got {tool_calls!r}")
tool_call = tool_calls[0]
if tool_call["function"]["name"] != "read_file":
    raise SystemExit(f"unexpected tool name: {tool_call!r}")
arguments = json.loads(tool_call["function"]["arguments"])
if arguments != {"path": "/workspace/README.md"}:
    raise SystemExit(f"unexpected tool arguments: {arguments!r}")
print("ok")
PY
)"
[[ "${chat_output}" == "ok" ]] || fail "chat completion tool-call probe failed"

responses_output="$(timeout 30 docker exec -i "${toolbox_cid}" python3 - "${responses_session}" <<'PY'
import json
import sys
import urllib.request

session = sys.argv[1]
payload = {
    "model": "trtllm/nemotron-cascade-2:30b",
    "input": "Use the read_file tool once for /workspace/README.md and stop.",
    "tools": [
        {
            "type": "function",
            "name": "read_file",
            "description": "Read a file",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"],
            },
        }
    ],
    "tool_choice": {"type": "function", "function": {"name": "read_file"}},
}
request = urllib.request.Request(
    "http://ollama-gate:11435/v1/responses",
    data=json.dumps(payload).encode("utf-8"),
    headers={
        "Content-Type": "application/json",
        "X-Agent-Project": "d11",
        "X-Agent-Session": session,
    },
    method="POST",
)
with urllib.request.urlopen(request, timeout=25) as response:
    body = json.loads(response.read().decode("utf-8"))
output = body.get("output")
if not isinstance(output, list):
    raise SystemExit(f"responses output missing: {output!r}")
function_calls = [item for item in output if isinstance(item, dict) and item.get("type") == "function_call"]
if len(function_calls) != 1:
    raise SystemExit(f"expected one function_call output item, got {function_calls!r}")
call = function_calls[0]
if call.get("name") != "read_file":
    raise SystemExit(f"unexpected function_call item: {call!r}")
arguments = json.loads(call.get("arguments", "{}"))
if arguments != {"path": "/workspace/README.md"}:
    raise SystemExit(f"unexpected function_call arguments: {arguments!r}")
print("ok")
PY
)"
[[ "${responses_output}" == "ok" ]] || fail "responses tool-call probe failed"

chat_line="$(grep "\"session\":\"${chat_session}\"" "${gate_log}" | tail -n 1 || true)"
[[ -n "${chat_line}" ]] || fail "missing gate log entry for ${chat_session}"
printf '%s\n' "${chat_line}" | grep -q '"backend":"trtllm"' \
  || fail "chat probe was not routed to trtllm (line=${chat_line})"

responses_line="$(grep "\"session\":\"${responses_session}\"" "${gate_log}" | tail -n 1 || true)"
[[ -n "${responses_line}" ]] || fail "missing gate log entry for ${responses_session}"
printf '%s\n' "${responses_line}" | grep -q '"backend":"trtllm"' \
  || fail "responses probe was not routed to trtllm (line=${responses_line})"

ok "trtllm backend returns tool calls for routed nemotron-cascade-2:30b requests"
ok "D11_trtllm_tool_calls passed"
