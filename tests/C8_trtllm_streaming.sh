#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

state_dir="${tmp_root}/state"
logs_dir="${tmp_root}/logs"
models_dir="${tmp_root}/models"
mkdir -p "${state_dir}" "${logs_dir}" "${models_dir}"

port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

server_log="${tmp_root}/trtllm-stream.log"
TRTLLM_RUNTIME_MODE=mock \
TRTLLM_LISTEN_HOST=127.0.0.1 \
TRTLLM_PORT="${port}" \
TRTLLM_STATE_DIR="${state_dir}" \
TRTLLM_LOGS_DIR="${logs_dir}" \
TRTLLM_MODELS_DIR="${models_dir}" \
python3 "${REPO_ROOT}/deployments/trtllm/server.py" >"${server_log}" 2>&1 &
server_pid=$!
trap 'kill "${server_pid}" >/dev/null 2>&1 || true; wait "${server_pid}" 2>/dev/null || true; rm -rf "${tmp_root}"' EXIT

python3 - "${port}" <<'PY' || fail "mock OpenAI-compatible TRT stream is broken"
import http.client
import json
import sys
import time

port = int(sys.argv[1])
deadline = time.time() + 10
while True:
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
        conn.request("GET", "/healthz")
        resp = conn.getresponse()
        resp.read()
        conn.close()
        break
    except OSError:
        if time.time() >= deadline:
            raise
        time.sleep(0.1)

payload = json.dumps(
    {
        "model": "https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8",
        "messages": [{"role": "user", "content": "Hello"}],
        "stream": True,
    }
)
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
conn.request("POST", "/v1/chat/completions", body=payload, headers={"Content-Type": "application/json"})
resp = conn.getresponse()
assert resp.status == 200, resp.status
assert "text/event-stream" in (resp.getheader("Content-Type") or "")
body = resp.read().decode("utf-8")
conn.close()
assert "data: {" in body, body
assert "chat.completion.chunk" in body, body
assert "data: [DONE]" in body, body
PY
ok "mock TRT OpenAI-compatible chat streaming emits SSE chunks"

python3 - "${port}" <<'PY' || fail "mock Ollama-style TRT stream is broken"
import http.client
import json
import sys

port = int(sys.argv[1])
payload = json.dumps(
    {
        "model": "https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8",
        "messages": [{"role": "user", "content": "Hello"}],
        "stream": True,
    }
)
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
conn.request("POST", "/api/chat", body=payload, headers={"Content-Type": "application/json"})
resp = conn.getresponse()
assert resp.status == 200, resp.status
assert "ndjson" in (resp.getheader("Content-Type") or "")
body = resp.read().decode("utf-8")
conn.close()
lines = [line for line in body.splitlines() if line.strip()]
assert len(lines) >= 2, lines
first = json.loads(lines[0])
last = json.loads(lines[-1])
assert first["done"] is False, first
assert last["done"] is True, last
PY
ok "mock TRT Ollama-compatible chat streaming emits chunked NDJSON"

ok "C8_trtllm_streaming passed"
