#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd docker
assert_cmd curl
assert_cmd python3

docker image inspect agentic/trtllm-runtime:local >/dev/null 2>&1 \
  || fail "missing local image agentic/trtllm-runtime:local; build core images first"
docker image inspect agentic/ollama-gate:local >/dev/null 2>&1 \
  || fail "missing local image agentic/ollama-gate:local; build core images first"

tmp_root="$(mktemp -d)"
network_name="codex-trt-native-hello-$$"
trt_name="codex-trt-native-hello-trt-$$"
gate_name="codex-trt-native-hello-gate-$$"

cleanup() {
  docker rm -f "${gate_name}" "${trt_name}" >/dev/null 2>&1 || true
  docker network rm "${network_name}" >/dev/null 2>&1 || true
  if [[ -d "${tmp_root}" ]]; then
    docker run --rm \
      -v "${tmp_root}:/cleanup" \
      --entrypoint /bin/sh \
      agentic/trtllm-runtime:local \
      -c "chown -R $(id -u):$(id -g) /cleanup" >/dev/null 2>&1 || true
    rm -rf "${tmp_root}" || true
  fi
}
trap cleanup EXIT

mkdir -p \
  "${tmp_root}/fake-bin" \
  "${tmp_root}/gate-config" \
  "${tmp_root}/gate-state" \
  "${tmp_root}/gate-logs" \
  "${tmp_root}/trt-state" \
  "${tmp_root}/trt-logs" \
  "${tmp_root}/trt-models/trtllm-model"

cat > "${tmp_root}/trt-models/trtllm-model/config.json" <<'JSON'
{"model_type":"nemotron_h"}
JSON

cat > "${tmp_root}/fake-bin/trtllm-serve" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec python3 /tmp/fake-native-server.py "$@"
SH
chmod +x "${tmp_root}/fake-bin/trtllm-serve"

cat > "${tmp_root}/fake-native-server.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def parse_args(argv: list[str]) -> tuple[str, str, int]:
    args = list(argv)
    if args and args[0] == "serve":
        args = args[1:]
    model = args[0] if args else "fake-native-model"
    host = "127.0.0.1"
    port = 8355
    idx = 1
    while idx < len(args):
        key = args[idx]
        if key == "--host" and idx + 1 < len(args):
            host = args[idx + 1]
            idx += 2
            continue
        if key == "--port" and idx + 1 < len(args):
            port = int(args[idx + 1])
            idx += 2
            continue
        idx += 1
    return model, host, port


MODEL, HOST, PORT = parse_args(sys.argv[1:])
STARTUP_DELAY = float(os.environ.get("FAKE_TRTLLM_NATIVE_STARTUP_DELAY_SECONDS", "0"))
RESPONSE_TEXT = os.environ.get("FAKE_TRTLLM_NATIVE_RESPONSE_TEXT", "Hello from fake native TRT backend")
time.sleep(STARTUP_DELAY)


class Handler(BaseHTTPRequestHandler):
    server_version = "fake-trtllm-native/0.1"
    protocol_version = "HTTP/1.1"

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        raw_length = self.headers.get("Content-Length", "0")
        size = int(raw_length)
        data = self.rfile.read(size) if size > 0 else b"{}"
        payload = json.loads(data.decode("utf-8"))
        return payload if isinstance(payload, dict) else {}

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._send_json(HTTPStatus.OK, {"status": "ok", "native_backend": True})
            return
        if self.path == "/v1/models":
            self._send_json(
                HTTPStatus.OK,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": MODEL,
                            "object": "model",
                            "owned_by": "fake-native-trtllm",
                        }
                    ],
                },
            )
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_POST(self) -> None:
        if self.path != "/v1/chat/completions":
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        payload = self._read_json()
        requested_model = payload.get("model") if isinstance(payload.get("model"), str) else MODEL
        self._send_json(
            HTTPStatus.OK,
            {
                "id": "chatcmpl-fake-native",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": requested_model,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": RESPONSE_TEXT},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {"prompt_tokens": 1, "completion_tokens": 7, "total_tokens": 8},
            },
        )

    def log_message(self, fmt: str, *args: object) -> None:
        return


ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
PY

cat > "${tmp_root}/gate-config/model_routes.yml" <<YAML
version: 1
defaults:
  backend: trtllm
backends:
  trtllm:
    protocol: ollama
    base_url: http://${trt_name}:11436
routes:
  - name: default-trt
    backend: trtllm
    match:
      - "https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8"
      - "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8"
      - "trtllm/nvidia-nemotron-3-nano-30b-a3b-fp8"
YAML

gate_port="$(python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"

docker network create "${network_name}" >/dev/null

docker run -d \
  --name "${trt_name}" \
  --network "${network_name}" \
  -e TRTLLM_RUNTIME_MODE=native \
  -e TRTLLM_LISTEN_HOST=0.0.0.0 \
  -e TRTLLM_PORT=11436 \
  -e TRTLLM_NATIVE_START_TIMEOUT_SECONDS=30 \
  -e TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" \
  -e TRTLLM_NATIVE_MODEL_POLICY=strict-nvfp4-local-only \
  -e TRTLLM_NVFP4_LOCAL_MODEL_DIR=/models/trtllm-model \
  -e TRTLLM_STATE_DIR=/state \
  -e TRTLLM_LOGS_DIR=/logs \
  -e TRTLLM_MODELS_DIR=/models \
  -e FAKE_TRTLLM_NATIVE_STARTUP_DELAY_SECONDS=12 \
  -e FAKE_TRTLLM_NATIVE_RESPONSE_TEXT="Hello from native TRT warmup test" \
  -v "${tmp_root}/fake-bin/trtllm-serve:/usr/local/bin/trtllm-serve:ro" \
  -v "${tmp_root}/fake-native-server.py:/tmp/fake-native-server.py:ro" \
  -v "${tmp_root}/trt-state:/state" \
  -v "${tmp_root}/trt-logs:/logs" \
  -v "${tmp_root}/trt-models:/models" \
  agentic/trtllm-runtime:local >/dev/null

docker run -d \
  --name "${gate_name}" \
  --network "${network_name}" \
  -p "127.0.0.1:${gate_port}:11435" \
  -e OLLAMA_BASE_URL="http://${trt_name}:11436" \
  -e TRTLLM_BASE_URL="http://${trt_name}:11436" \
  -e GATE_MODEL_ROUTES_FILE=/gate/config/model_routes.yml \
  -e GATE_STATE_DIR=/gate/state \
  -e GATE_LOG_FILE=/gate/logs/gate.jsonl \
  -v "${tmp_root}/gate-config:/gate/config:ro" \
  -v "${tmp_root}/gate-state:/gate/state" \
  -v "${tmp_root}/gate-logs:/gate/logs" \
  agentic/ollama-gate:local >/dev/null

for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${gate_port}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "http://127.0.0.1:${gate_port}/healthz" >/dev/null \
  || fail "ollama-gate did not become ready on port ${gate_port}"

python3 - "${tmp_root}/trt-state/runtime-state.json" <<'PY' \
  || fail "trtllm runtime-state did not expose native warm-up in progress"
import json
import pathlib
import sys
import time

path = pathlib.Path(sys.argv[1])
deadline = time.time() + 8
last = None
while time.time() < deadline:
    if path.exists():
        last = json.loads(path.read_text(encoding="utf-8"))
        if last.get("runtime_mode_effective") == "native" and last.get("native_ready") is False:
            raise SystemExit(0)
    time.sleep(0.25)

raise SystemExit(f"runtime-state never exposed native warm-up in progress: {last!r}")
PY
ok "trtllm runtime-state exposes native warm-up in progress before the first hello"

prewarm_status="$(curl -sS -o "${tmp_root}/prewarm-body.json" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d '{"model":"https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8","messages":[{"role":"user","content":"Hello"}]}' \
  "http://127.0.0.1:${gate_port}/api/chat")"
[[ "${prewarm_status}" == "503" ]] || {
  cat "${tmp_root}/prewarm-body.json" >&2 || true
  fail "gate request before native warm-up should return 503 (got ${prewarm_status})"
}
python3 - "${tmp_root}/prewarm-body.json" <<'PY' || fail "pre-warm gate payload must expose native starting status"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
error = payload["error"]
assert error["type"] == "backend_unavailable", payload
assert error["backend"] == "trtllm", payload
assert '"status": "starting"' in error["detail"], payload
assert '"runtime_mode_effective": "native"' in error["detail"], payload
PY
ok "gate surfaces TRT native warm-up state before the first hello succeeds"

python3 - "${tmp_root}/trt-state/runtime-state.json" <<'PY' || fail "native TRT runtime did not become ready after warm-up"
import json
import pathlib
import sys
import time

path = pathlib.Path(sys.argv[1])
deadline = time.time() + 20
last = None
while time.time() < deadline:
    if path.exists():
        last = json.loads(path.read_text(encoding="utf-8"))
        if last.get("runtime_mode_effective") == "native" and last.get("native_ready") is True:
            raise SystemExit(0)
    time.sleep(0.5)

raise SystemExit(f"runtime state never reached native_ready=true: {last!r}")
PY
ok "trtllm native warm-up completes and marks runtime-state native_ready=true"

timeout 15 docker exec "${trt_name}" python3 - <<'PY' \
  || fail "trtllm /healthz did not report native_ready=true after warm-up"
import json
import urllib.request

with urllib.request.urlopen("http://127.0.0.1:11436/healthz", timeout=5) as response:
    payload = json.loads(response.read().decode("utf-8"))

assert payload["status"] == "ok", payload
assert payload["runtime_mode_effective"] == "native", payload
assert payload["native_ready"] is True, payload
PY
ok "trtllm /healthz reports status=ok with native_ready=true after warm-up"

hello_status="$(curl -sS \
  -D "${tmp_root}/hello-headers.txt" \
  -o "${tmp_root}/hello-body.json" \
  -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -H 'X-Agent-Project: c10' \
  -H 'X-Agent-Session: c10-hello-native-warmup' \
  -d '{"model":"https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8","messages":[{"role":"user","content":"Hello"}]}' \
  "http://127.0.0.1:${gate_port}/api/chat")"
[[ "${hello_status}" == "200" ]] || {
  cat "${tmp_root}/hello-headers.txt" >&2 || true
  cat "${tmp_root}/hello-body.json" >&2 || true
  fail "gate hello after native warm-up returned status ${hello_status}"
}

grep -qi '^x-gate-backend: trtllm' "${tmp_root}/hello-headers.txt" \
  || fail "gate hello response must report backend trtllm"
python3 - "${tmp_root}/hello-body.json" <<'PY' || fail "gate hello response body is invalid"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["model"] == "https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8", payload
assert payload["message"]["role"] == "assistant", payload
assert payload["message"]["content"] == "Hello from native TRT warmup test", payload
assert payload["done"] is True, payload
PY
ok "first hello succeeds through ollama-gate after native TRT warm-up"

gate_line="$(grep '"session":"c10-hello-native-warmup"' "${tmp_root}/gate-logs/gate.jsonl" | tail -n 1 || true)"
[[ -n "${gate_line}" ]] || fail "gate log is missing the successful hello session"
printf '%s\n' "${gate_line}" | grep -q '"backend":"trtllm"' \
  || fail "successful hello session was not logged as backend=trtllm"
printf '%s\n' "${gate_line}" | grep -q '"status_code":200' \
  || fail "successful hello session was not logged with status_code=200"
ok "gate logs record backend=trtllm for the successful native hello"

ok "C10_trtllm_native_hello_gate_warmup passed"
