#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_H_TESTS:-0}" == "1" ]]; then
  ok "H2 skipped because AGENTIC_SKIP_H_TESTS=1"
  exit 0
fi

assert_cmd docker

openhands_port="${OPENHANDS_HOST_PORT:-3000}"
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

gate_log="${AGENTIC_ROOT:-/srv/agentic}/gate/logs/gate.jsonl"
[[ -s "${gate_log}" ]] || fail "gate log file missing or empty: ${gate_log}"
grep -q "\"session\":\"${session}\"" "${gate_log}" \
  || fail "gate logs do not contain the openhands smoke session"
ok "openhands-to-gate traffic is visible in gate logs"

ok "H2_openhands passed"
