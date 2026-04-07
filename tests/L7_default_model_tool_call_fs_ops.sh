#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L7 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd timeout
assert_cmd python3

default_model="${AGENTIC_DEFAULT_MODEL:-${OLLAMA_PRELOAD_GENERATE_MODEL:-nemotron-cascade-2:30b}}"
tool_timeout="${AGENTIC_DEFAULT_MODEL_TOOL_SMOKE_TIMEOUT_SECONDS:-360}"

services=(agentic-claude agentic-codex agentic-opencode agentic-vibestral agentic-hermes openhands)

run_tool_call_matrix_for_service() {
  local service="$1"
  local cid="$2"
  local label="${service#agentic-}"

  timeout "${tool_timeout}" docker exec \
    -e TEST_MODEL="${default_model}" \
    -e TEST_AGENT_LABEL="${label}" \
    -e TEST_HTTP_TIMEOUT_SECONDS="${tool_timeout}" \
    "${cid}" \
    python3 - <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import urllib.request

model = os.environ["TEST_MODEL"]
agent_label = os.environ["TEST_AGENT_LABEL"]
http_timeout = int(os.environ.get("TEST_HTTP_TIMEOUT_SECONDS", "240"))
endpoint = "http://ollama-gate:11435/v1/chat/completions"

workspace_root = pathlib.Path("/workspace")
test_dir = workspace_root / f".l7-toolcall-{agent_label}"
python_file = test_dir / "tool_smoke.py"
expected_output = f"l7-{agent_label}-ok"

tools = [
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write UTF-8 content into a file path",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read UTF-8 content from a file path",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_python",
            "description": "Run a python file and return stdout/stderr",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "delete_file",
            "description": "Delete a file if it exists",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"],
            },
        },
    },
]


def call_model(messages):
    payload = {
        "model": model,
        "messages": messages,
        "tools": tools,
        "temperature": 0,
        "stream": False,
    }
    req = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "X-Agent-Session": f"l7-{agent_label}",
            "X-Agent-Project": "l7-tool-calling",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=http_timeout) as resp:
        if resp.status != 200:
            raise RuntimeError(f"chat/completions HTTP status {resp.status}")
        body = json.loads(resp.read().decode("utf-8"))
    choices = body.get("choices") or []
    if not choices or not isinstance(choices[0], dict):
        raise RuntimeError("missing choices[0] in model response")
    message = choices[0].get("message")
    if not isinstance(message, dict):
        raise RuntimeError("missing choices[0].message in model response")
    return message


def tool_write_file(args):
    path = pathlib.Path(args["path"])
    content = str(args["content"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return {"ok": True, "path": str(path), "bytes": len(content)}


def tool_read_file(args):
    path = pathlib.Path(args["path"])
    content = path.read_text(encoding="utf-8")
    return {"ok": True, "path": str(path), "content": content}


def tool_run_python(args):
    path = pathlib.Path(args["path"])
    proc = subprocess.run(
        ["python3", str(path)],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    return {
        "ok": proc.returncode == 0,
        "path": str(path),
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


def tool_delete_file(args):
    path = pathlib.Path(args["path"])
    existed = path.exists()
    if existed:
        path.unlink()
    return {"ok": True, "path": str(path), "deleted": existed}


tool_impl = {
    "write_file": tool_write_file,
    "read_file": tool_read_file,
    "run_python": tool_run_python,
    "delete_file": tool_delete_file,
}

messages = [
    {
        "role": "system",
        "content": (
            "You are a strict tool-calling assistant. "
            "Always use tools for actions and call exactly one tool when asked."
        ),
    }
]

steps = [
    (
        "write_file",
        (
            f"Call write_file to create this Python file: {python_file}. "
            f"Use content exactly: print('{expected_output}')\\n"
        ),
    ),
    ("read_file", f"Call read_file on this exact path: {python_file}"),
    ("run_python", f"Call run_python on this exact path: {python_file}"),
    ("delete_file", f"Call delete_file on this exact path: {python_file}"),
]

for expected_tool, user_prompt in steps:
    messages.append({"role": "user", "content": user_prompt})
    step_ok = False

    for _ in range(3):
        assistant_message = call_model(messages)
        tool_calls = assistant_message.get("tool_calls") or []
        if not tool_calls:
            messages.append(assistant_message)
            messages.append(
                {
                    "role": "user",
                    "content": f"You must call tool '{expected_tool}' now. No plain text.",
                }
            )
            continue

        tool_call = tool_calls[0]
        fn = ((tool_call.get("function") or {}).get("name") or "").strip()
        args_raw = (tool_call.get("function") or {}).get("arguments") or "{}"
        if fn != expected_tool:
            raise RuntimeError(f"expected tool '{expected_tool}', got '{fn}'")

        args = json.loads(args_raw)
        result = tool_impl[fn](args)

        if expected_tool == "read_file":
            content = str(result.get("content", ""))
            if expected_output not in content:
                raise RuntimeError("read_file content does not contain expected script output marker")
        if expected_tool == "run_python":
            if not result.get("ok"):
                raise RuntimeError(f"run_python failed: {result}")
            stdout = str(result.get("stdout", ""))
            if expected_output not in stdout:
                raise RuntimeError(f"run_python stdout missing expected marker: {stdout!r}")
        if expected_tool == "delete_file":
            if pathlib.Path(args["path"]).exists():
                raise RuntimeError("delete_file did not remove target file")

        messages.append({"role": "assistant", "tool_calls": tool_calls})
        messages.append(
            {
                "role": "tool",
                "tool_call_id": tool_call.get("id"),
                "name": fn,
                "content": json.dumps(result, ensure_ascii=True),
            }
        )
        step_ok = True
        break

    if not step_ok:
        raise RuntimeError(f"step '{expected_tool}' failed to produce a tool call")

if python_file.exists():
    raise RuntimeError(f"python file still exists after delete step: {python_file}")

print(f"OK: {agent_label} tool-calling write/read/run/delete passed with model={model}")
PY
}

for service in "${services[@]}"; do
  cid="$(require_service_container "${service}")" || exit 1
  wait_for_container_ready "${cid}" 180 || fail "${service} is not ready"
  run_tool_call_matrix_for_service "${service}" "${cid}" \
    || fail "${service} failed tool-calling filesystem workflow"
  ok "${service} passed tool-calling filesystem workflow"
done

ok "L7_default_model_tool_call_fs_ops passed"
