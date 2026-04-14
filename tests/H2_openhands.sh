#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

if [[ "${AGENTIC_SKIP_H_TESTS:-0}" == "1" ]]; then
  ok "H2 skipped because AGENTIC_SKIP_H_TESTS=1"
  exit 0
fi

assert_cmd docker

openhands_port="${OPENHANDS_HOST_PORT:-3000}"
expected_context_budget="${AGENTIC_CONTEXT_BUDGET_TOKENS:-${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-50909}}"
expected_soft_threshold="${AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS:-38181}"
expected_danger_threshold="${AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS:-45818}"
runtime_env_file="${AGENTIC_ROOT:-/srv/agentic}/deployments/runtime.env"
if [[ -f "${runtime_env_file}" ]]; then
  runtime_value="$(sed -n 's/^AGENTIC_CONTEXT_BUDGET_TOKENS=//p' "${runtime_env_file}" | head -n 1)"
  if [[ -n "${runtime_value}" ]]; then
    expected_context_budget="${runtime_value}"
  fi
  runtime_value="$(sed -n 's/^AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS=//p' "${runtime_env_file}" | head -n 1)"
  if [[ -n "${runtime_value}" ]]; then
    expected_soft_threshold="${runtime_value}"
  fi
  runtime_value="$(sed -n 's/^AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS=//p' "${runtime_env_file}" | head -n 1)"
  if [[ -n "${runtime_value}" ]]; then
    expected_danger_threshold="${runtime_value}"
  fi
fi
openhands_cid="$(require_service_container openhands)" || exit 1
gate_cid="$(require_service_container ollama-gate)" || exit 1

wait_for_container_ready "${openhands_cid}" 180 || fail "openhands is not ready"
wait_for_container_ready "${gate_cid}" 90 || fail "ollama-gate is not ready"

assert_no_public_bind "${openhands_port}" || fail "openhands host bind is not loopback-only"
ok "openhands host bind is loopback-only"

docker inspect --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' "${openhands_cid}" \
  | grep -q '/var/run/docker.sock' \
  && fail "openhands mounts docker.sock, which is forbidden"
ok "openhands does not mount docker.sock"

timeout 20 docker exec "${openhands_cid}" sh -lc \
  'command -v git >/dev/null && command -v python3 >/dev/null && python3 -c "import pytest" >/dev/null' \
  || fail "openhands repo task toolchain must provide git, python3, and pytest"
ok "openhands repo task toolchain is available"

timeout 20 docker exec "${openhands_cid}" /app/.venv/bin/python - <<'PY' || fail "openhands default agent tools must include moderated discovery tools"
from openhands.app_server.app_conversation.live_status_app_conversation_service import (
    OPENHANDS_EXTRA_DEFAULT_TOOL_NAMES,
    get_enriched_default_tools,
)

tool_names = {getattr(tool, "name", None) for tool in get_enriched_default_tools()}
required = {"terminal", "file_editor", "task_tracker"} | set(OPENHANDS_EXTRA_DEFAULT_TOOL_NAMES)
missing = sorted(name for name in required if name not in tool_names)
assert not missing, missing
PY
ok "openhands default agent tools include moderated discovery tools"

env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${openhands_cid}")"
echo "${env_dump}" | grep -q '^LLM_BASE_URL=http://ollama-gate:11435/v1$' \
  || fail "openhands LLM_BASE_URL is not pinned to ollama-gate"
ok "openhands is configured to use ollama-gate"
echo "${env_dump}" | grep -q '^LLM_MODEL=' \
  || fail "openhands LLM_MODEL is missing"
echo "${env_dump}" | grep -q '^LLM_API_KEY=' \
  || fail "openhands LLM_API_KEY is missing"
echo "${env_dump}" | grep -q '^HOME=/.openhands/home$' \
  || fail "openhands HOME must be set to /.openhands/home"
echo "${env_dump}" | grep -q '^AGENT_HOME=/.openhands/home$' \
  || fail "openhands AGENT_HOME must be set to /.openhands/home"
echo "${env_dump}" | grep -q "^AGENTIC_CONTEXT_BUDGET_TOKENS=${expected_context_budget}$" \
  || fail "openhands must set AGENTIC_CONTEXT_BUDGET_TOKENS=${expected_context_budget}"
echo "${env_dump}" | grep -q "^AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS=${expected_soft_threshold}$" \
  || fail "openhands must set AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS=${expected_soft_threshold}"
echo "${env_dump}" | grep -q "^AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS=${expected_danger_threshold}$" \
  || fail "openhands must set AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS=${expected_danger_threshold}"
ok "openhands model/api key env is present"

settings_payload="$(curl -fsS --max-time 10 "http://127.0.0.1:${openhands_port}/api/settings" || true)"
[[ -n "${settings_payload}" ]] || fail "openhands settings endpoint returned empty payload"
printf '%s' "${settings_payload}" | grep -q '"llm_api_key_set":true' \
  || fail "openhands settings preconfiguration missing llm_api_key_set=true"
printf '%s' "${settings_payload}" | grep -q '"llm_base_url":"http://ollama-gate:11435/v1"' \
  || fail "openhands settings preconfiguration missing llm_base_url"
printf '%s' "${settings_payload}" | grep -q '"llm_model":"openai/' \
  || fail "openhands settings preconfiguration missing provider-qualified llm_model"
ok "openhands first-run settings are preconfigured"

restart_before="$(docker inspect --format '{{.RestartCount}}' "${openhands_cid}" 2>/dev/null || echo "0")"
python3 - "${openhands_port}" <<'PY' || fail "openhands app-conversation startup flow is unstable"
import json
import sys
import time
import urllib.request

port = int(sys.argv[1])
base = f"http://127.0.0.1:{port}"
created = 0

for idx in range(1, 4):
    payload = {
        "title": f"h2-conversation-{idx}",
        "agent_type": "default",
        "initial_message": {
            "role": "user",
            "content": [{"type": "text", "text": f"openhands startup smoke {idx}"}],
            "run": False,
        },
    }
    req = urllib.request.Request(
        f"{base}/api/v1/app-conversations",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        task = json.loads(resp.read().decode("utf-8"))
    task_id = task.get("id")
    if not isinstance(task_id, str) or not task_id:
        raise SystemExit(f"missing start-task id for conversation {idx}: {task}")

    deadline = time.time() + 90
    last_status = None
    while time.time() < deadline:
        with urllib.request.urlopen(
            f"{base}/api/v1/app-conversations/start-tasks?ids={task_id}", timeout=30
        ) as resp:
            tasks = json.loads(resp.read().decode("utf-8"))
        if isinstance(tasks, list) and tasks:
            state = tasks[0] or {}
            last_status = state.get("status")
            if last_status == "READY":
                created += 1
                break
            if last_status == "ERROR":
                raise SystemExit(f"start-task {task_id} failed: {state.get('detail')}")
        time.sleep(1)

    if last_status != "READY":
        raise SystemExit(f"start-task {task_id} did not reach READY (last={last_status})")

print(f"created_ready_conversations={created}")
PY
ok "openhands can create and initialize multiple conversations"

python3 - "${openhands_port}" <<'PY' || fail "openhands V1 message bridge is broken"
import json
import sys
import time
import urllib.parse
import urllib.request

port = int(sys.argv[1])
base = f"http://127.0.0.1:{port}"

req = urllib.request.Request(
    f"{base}/api/v1/app-conversations",
    data=json.dumps({"title": "h2-message-bridge", "agent_type": "default"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=30) as resp:
    task = json.loads(resp.read().decode("utf-8"))
task_id = task.get("id")
if not isinstance(task_id, str) or not task_id:
    raise SystemExit(f"missing start-task id for message bridge: {task}")

deadline = time.time() + 90
conversation_id = None
while time.time() < deadline:
    with urllib.request.urlopen(
        f"{base}/api/v1/app-conversations/start-tasks?ids={task_id}", timeout=30
    ) as resp:
        tasks = json.loads(resp.read().decode("utf-8"))
    if isinstance(tasks, list) and tasks:
        state = tasks[0] or {}
        status = state.get("status")
        if status == "READY":
            conversation_id = state.get("app_conversation_id")
            break
        if status == "ERROR":
            raise SystemExit(f"start-task {task_id} failed before message bridge: {state.get('detail')}")
    time.sleep(1)

if not conversation_id:
    raise SystemExit(f"message bridge conversation did not reach READY (task={task_id})")

with urllib.request.urlopen(
    f"{base}/api/conversations/{conversation_id}", timeout=30
) as resp:
    conversation_info = json.loads(resp.read().decode("utf-8"))

conversation_url = conversation_info.get("url")
if not isinstance(conversation_url, str) or not conversation_url:
    raise SystemExit(f"conversation URL missing from legacy payload: {conversation_info}")
if conversation_url.startswith("http://localhost:8000/"):
    raise SystemExit(f"conversation URL still points to internal runtime localhost: {conversation_url}")

bridge_url = urllib.parse.urljoin(f"{base}/", conversation_url.lstrip("/"))
message_req = urllib.request.Request(
    f"{bridge_url.rstrip('/')}/message",
    data=json.dumps({"message": "openhands v1 message bridge smoke"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(message_req, timeout=30) as resp:
    if resp.status != 200:
        raise SystemExit(f"unexpected /message status={resp.status}")
    body = json.loads(resp.read().decode("utf-8"))

if not isinstance(body, dict) or body.get("success") is not True:
    raise SystemExit(f"unexpected /message response: {body}")

deadline = time.time() + 45
events_page = None
found_text = False
while time.time() < deadline:
    with urllib.request.urlopen(
        f"{base}/api/v1/conversation/{conversation_id}/events/search?limit=100", timeout=30
    ) as resp:
        candidate = json.loads(resp.read().decode("utf-8"))
    items = candidate.get("items") if isinstance(candidate, dict) else None
    if isinstance(items, list):
        events_page = candidate
        expected_text = "openhands v1 message bridge smoke"
        for item in items:
            if not isinstance(item, dict):
                continue
            llm_message = item.get("llm_message")
            if not isinstance(llm_message, dict):
                continue
            content = llm_message.get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") != "text":
                    continue
                text = block.get("text")
                if isinstance(text, str) and expected_text in text:
                    found_text = True
                    break
            if found_text:
                break
    if found_text:
        break
    time.sleep(1)

if not isinstance(events_page, dict):
    raise SystemExit("v1 app event stream stayed empty after /message bridge")

items = events_page.get("items")
if not isinstance(items, list):
    raise SystemExit(f"unexpected v1 event search payload: {events_page}")

if not found_text:
    raise SystemExit(
        f"message bridge text not found in v1 app event stream (items={len(items)})"
    )
PY
ok "openhands V1 message bridge is operational"

ws_bridge_conversation_id="$(
python3 - "${openhands_port}" <<'PY'
import json
import sys
import time
import urllib.request

port = int(sys.argv[1])
base = f"http://127.0.0.1:{port}"

req = urllib.request.Request(
    f"{base}/api/v1/app-conversations",
    data=json.dumps({"title": "h2-websocket-bridge", "agent_type": "default"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=30) as resp:
    task = json.loads(resp.read().decode("utf-8"))
task_id = task.get("id")
if not isinstance(task_id, str) or not task_id:
    raise SystemExit(f"missing start-task id for websocket bridge: {task}")

deadline = time.time() + 90
conversation_id = None
while time.time() < deadline:
    with urllib.request.urlopen(
        f"{base}/api/v1/app-conversations/start-tasks?ids={task_id}", timeout=30
    ) as resp:
        tasks = json.loads(resp.read().decode("utf-8"))
    if isinstance(tasks, list) and tasks:
        state = tasks[0] or {}
        status = state.get("status")
        if status == "READY":
            conversation_id = state.get("app_conversation_id")
            break
        if status == "ERROR":
            raise SystemExit(f"start-task {task_id} failed before websocket bridge: {state.get('detail')}")
    time.sleep(1)

if not conversation_id:
    raise SystemExit(f"websocket bridge conversation did not reach READY (task={task_id})")

print(conversation_id)
PY
)" || fail "unable to create V1 conversation for websocket bridge smoke"

[[ -n "${ws_bridge_conversation_id}" ]] || fail "websocket bridge smoke conversation id is empty"
timeout 60 docker exec -i "${openhands_cid}" /app/.venv/bin/python - "${openhands_port}" "${ws_bridge_conversation_id}" <<'PY' || fail "openhands V1 websocket bridge is broken"
import asyncio
import json
import sys
import urllib.request

import websockets

port = int(sys.argv[1])
conversation_id = sys.argv[2]
expected_text = "openhands v1 websocket bridge smoke"


async def run_smoke() -> None:
    ws_url = f"ws://127.0.0.1:{port}/sockets/events/{conversation_id}"
    async with websockets.connect(ws_url, open_timeout=15, close_timeout=5) as ws:
        pong_waiter = await ws.ping()
        await asyncio.wait_for(pong_waiter, timeout=10)

        message_req = urllib.request.Request(
            f"http://127.0.0.1:{port}/api/conversations/{conversation_id}/message",
            data=json.dumps({"message": expected_text}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(message_req, timeout=30) as resp:
            if resp.status != 200:
                raise SystemExit(f"unexpected /message status={resp.status}")
            body = json.loads(resp.read().decode("utf-8"))
        if not isinstance(body, dict) or body.get("success") is not True:
            raise SystemExit(f"unexpected /message response during websocket smoke: {body}")

        deadline = asyncio.get_running_loop().time() + 30
        while asyncio.get_running_loop().time() < deadline:
            remaining = deadline - asyncio.get_running_loop().time()
            payload = await asyncio.wait_for(ws.recv(), timeout=remaining)
            text = payload.decode("utf-8", errors="ignore") if isinstance(payload, bytes) else str(payload)
            if expected_text in text:
                return
        raise SystemExit("websocket bridge did not relay the submitted message event")


asyncio.run(run_smoke())
PY
ok "openhands V1 websocket bridge is operational"

restart_after="$(docker inspect --format '{{.RestartCount}}' "${openhands_cid}" 2>/dev/null || echo "0")"
[[ "${restart_after}" == "${restart_before}" ]] \
  || fail "openhands container restarted during conversation startup flow (before=${restart_before}, after=${restart_after})"
ok "openhands container remains stable during conversation startup"

session="h2-openhands-$RANDOM-$$"
timeout 20 docker exec "${openhands_cid}" sh -lc "python3 - <<'PY'
import time
import urllib.error
import urllib.request

req = urllib.request.Request(
  'http://ollama-gate:11435/api/version',
  headers={
    'X-Agent-Session': '${session}',
    'X-Agent-Project': 'openhands',
  },
  method='GET'
)
for _attempt in range(5):
  try:
    with urllib.request.urlopen(req, timeout=10) as resp:
      if resp.status == 200:
        raise SystemExit(0)
      raise SystemExit(1)
  except urllib.error.HTTPError as exc:
    if exc.code == 429:
      time.sleep(1)
      continue
    raise
raise SystemExit(1)
PY" || fail "openhands container failed to call ollama-gate"

gate_log="$(resolve_gate_log_path "${gate_cid}")" || fail "unable to resolve active gate log path"
[[ -s "${gate_log}" ]] || fail "gate log file missing or empty: ${gate_log}"
grep -q "\"session\":\"${session}\"" "${gate_log}" \
  || fail "gate logs do not contain the openhands smoke session"
ok "openhands-to-gate traffic is visible in gate logs"

ok "H2_openhands passed"
