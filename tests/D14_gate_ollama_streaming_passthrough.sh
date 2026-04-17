#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd docker
assert_cmd curl
assert_cmd python3

docker image inspect agentic/ollama-gate:local >/dev/null 2>&1 \
  || fail "missing local image agentic/ollama-gate:local; build core images first"

tmp_root="$(mktemp -d)"
network_name="codex-ollama-stream-$$"
mock_name="codex-ollama-stream-mock-$$"
gate_name="codex-ollama-stream-gate-$$"

cleanup() {
  docker rm -f "${gate_name}" "${mock_name}" >/dev/null 2>&1 || true
  docker network rm "${network_name}" >/dev/null 2>&1 || true
  rm -rf "${tmp_root}" || true
}
trap cleanup EXIT

mkdir -p \
  "${tmp_root}/gate-config" \
  "${tmp_root}/gate-state" \
  "${tmp_root}/gate-logs"

cat >"${tmp_root}/gate-config/model_routes.yml" <<'YAML'
version: 1
defaults:
  backend: ollama
backends:
  ollama:
    protocol: ollama
    base_url: http://codex-ollama-stream-mock-PLACEHOLDER:18080
routes:
  - name: default-ollama
    backend: ollama
    match:
      - "mock-ollama-stream"
YAML
sed -i "s/codex-ollama-stream-mock-PLACEHOLDER/${mock_name}/g" "${tmp_root}/gate-config/model_routes.yml"

docker network create "${network_name}" >/dev/null

docker run -d \
  --name "${mock_name}" \
  --network "${network_name}" \
  --entrypoint python3 \
  agentic/ollama-gate:local \
  -u -c '
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path == "/api/version":
            body = b"{\"version\":\"mock\"}"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)

        if self.path == "/v1/chat/completions":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            events = [
                "data: {\"id\":\"mock-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n",
                "data: {\"id\":\"mock-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"upstream-first\"},\"finish_reason\":null}]}\n\n",
                "data: {\"id\":\"mock-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" upstream-second\"},\"finish_reason\":null}]}\n\n",
                "data: {\"id\":\"mock-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
                "data: [DONE]\n\n",
            ]
            for idx, event in enumerate(events):
                self.wfile.write(event.encode("utf-8"))
                self.wfile.flush()
                if idx < len(events) - 1:
                    time.sleep(1.0)
            self.close_connection = True
            return

        if self.path == "/api/chat":
            time.sleep(2.2)
            body = json.dumps(
                {
                    "model": "mock-ollama-stream",
                    "created_at": "2026-04-17T00:00:00Z",
                    "message": {"role": "assistant", "content": "buffered via api/chat"},
                    "done": True,
                    "done_reason": "stop",
                }
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            return

        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


ThreadingHTTPServer(("0.0.0.0", 18080), Handler).serve_forever()
' >/dev/null

docker run -d \
  --name "${gate_name}" \
  --network "${network_name}" \
  -p 127.0.0.1:18036:11435 \
  -e OLLAMA_BASE_URL="http://${mock_name}:18080" \
  -e GATE_MODEL_ROUTES_FILE=/gate/config/model_routes.yml \
  -e GATE_STATE_DIR=/gate/state \
  -e GATE_LOG_FILE=/gate/logs/gate.jsonl \
  -v "${tmp_root}/gate-config:/gate/config:ro" \
  -v "${tmp_root}/gate-state:/gate/state" \
  -v "${tmp_root}/gate-logs:/gate/logs" \
  agentic/ollama-gate:local >/dev/null

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:18036/healthz >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

metrics_file="${tmp_root}/stream-metrics.txt"
body_file="${tmp_root}/stream-body.txt"
headers_file="${tmp_root}/stream-headers.txt"

python3 - "${metrics_file}" "${body_file}" "${headers_file}" <<'PY'
import requests
import sys
import time

metrics_file, body_file, headers_file = sys.argv[1:4]
payload = {
    "model": "mock-ollama-stream",
    "messages": [{"role": "user", "content": "hello"}],
    "stream": True,
}
start = time.monotonic()
with requests.post(
    "http://127.0.0.1:18036/v1/chat/completions",
    json=payload,
    stream=True,
    timeout=(10, 20),
) as response:
    first_line = None
    lines = []
    with open(headers_file, "w", encoding="utf-8") as fh:
        for key, value in response.headers.items():
            fh.write(f"{key}: {value}\n")
    for raw_line in response.iter_lines(decode_unicode=True):
        if raw_line is None:
            continue
        if raw_line and first_line is None:
            first_line = time.monotonic()
        lines.append(raw_line)
    total = time.monotonic()
with open(metrics_file, "w", encoding="utf-8") as fh:
    fh.write(f"status={response.status_code}\n")
    fh.write(f"first_line_after_sec={-1 if first_line is None else first_line - start:.3f}\n")
    fh.write(f"total_after_sec={total - start:.3f}\n")
with open(body_file, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines))
    fh.write("\n")
PY

status_code="$(sed -n 's/^status=//p' "${metrics_file}")"
first_line_after_sec="$(sed -n 's/^first_line_after_sec=//p' "${metrics_file}")"
total_after_sec="$(sed -n 's/^total_after_sec=//p' "${metrics_file}")"

[[ "${status_code}" == "200" ]] || {
  cat "${headers_file}" >&2 || true
  cat "${body_file}" >&2 || true
  fail "gate Ollama streaming request returned status ${status_code}"
}

grep -qi '^content-type: text/event-stream' "${headers_file}" \
  || fail "gate Ollama streaming response is not SSE"
grep -qi '^x-gate-backend: ollama' "${headers_file}" \
  || fail "gate Ollama streaming response did not route to ollama"
grep -q 'upstream-first' "${body_file}" \
  || fail "gate Ollama streaming response did not preserve upstream streamed chunk"
grep -q '^data: \[DONE\]$' "${body_file}" \
  || fail "gate Ollama streaming response missing [DONE] terminator"
if grep -q 'buffered via api/chat' "${body_file}"; then
  fail "gate Ollama streaming response still came from buffered /api/chat path"
fi

python3 - "${first_line_after_sec}" "${total_after_sec}" <<'PY'
import sys

first = float(sys.argv[1])
total = float(sys.argv[2])
assert 0 <= first < 0.8, (first, total)
assert total > 3.0, (first, total)
PY

ok "gate relays native Ollama streaming chunks before the completion finishes"
