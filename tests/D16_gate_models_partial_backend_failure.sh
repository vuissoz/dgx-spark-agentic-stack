#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd docker
assert_cmd curl
assert_cmd python3

docker image inspect agentic/ollama-gate:local >/dev/null 2>&1 \
  || fail "missing local image agentic/ollama-gate:local; build core images first"

tmp_root="$(mktemp -d)"
network_name="codex-gate-models-partial-$$"
ollama_mock_name="codex-gate-models-ollama-$$"
openai_mock_name="codex-gate-models-openai-$$"
gate_name="codex-gate-models-gate-$$"
gate_port="$(pick_free_loopback_port 18040 100)"
headers_file="$(mktemp)"
body_file="$(mktemp)"

cleanup() {
  docker rm -f "${gate_name}" "${ollama_mock_name}" "${openai_mock_name}" >/dev/null 2>&1 || true
  docker network rm "${network_name}" >/dev/null 2>&1 || true
  rm -f "${headers_file}" "${body_file}" >/dev/null 2>&1 || true
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
    base_url: http://OLLAMA_MOCK_PLACEHOLDER:18080
  trtllm:
    protocol: openai
    base_url: http://OPENAI_MOCK_PLACEHOLDER:18081/v1
routes:
  - name: default-ollama
    backend: ollama
    match:
      - "*"
YAML
sed -i "s/OLLAMA_MOCK_PLACEHOLDER/${ollama_mock_name}/g" "${tmp_root}/gate-config/model_routes.yml"
sed -i "s/OPENAI_MOCK_PLACEHOLDER/${openai_mock_name}/g" "${tmp_root}/gate-config/model_routes.yml"

docker network create "${network_name}" >/dev/null

docker run -d \
  --name "${ollama_mock_name}" \
  --network "${network_name}" \
  --entrypoint python3 \
  agentic/ollama-gate:local \
  -u -c '
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _json_response(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def do_GET(self):
        if self.path == "/api/version":
            self._json_response(200, {"version": "mock"})
            return
        if self.path == "/api/tags":
            self._json_response(
                200,
                {
                    "models": [
                        {
                            "name": "mock-ollama:latest",
                            "model": "mock-ollama:latest",
                            "digest": "sha256:mockollama",
                            "size": 1234,
                            "modified_at": "2026-06-07T12:00:00Z",
                            "details": {"family": "mock"},
                        }
                    ]
                },
            )
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


ThreadingHTTPServer(("0.0.0.0", 18080), Handler).serve_forever()
' >/dev/null

docker run -d \
  --name "${openai_mock_name}" \
  --network "${network_name}" \
  --entrypoint python3 \
  agentic/ollama-gate:local \
  -u -c '
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path == "/v1/models":
            body = json.dumps({"error": {"message": "trt unavailable"}}).encode("utf-8")
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


ThreadingHTTPServer(("0.0.0.0", 18081), Handler).serve_forever()
' >/dev/null

docker run -d \
  --name "${gate_name}" \
  --network "${network_name}" \
  -p "127.0.0.1:${gate_port}:11435" \
  -e OLLAMA_BASE_URL="http://${ollama_mock_name}:18080" \
  -e TRTLLM_BASE_URL="http://${openai_mock_name}:18081/v1" \
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

status_code="$(curl -sS -D "${headers_file}" -o "${body_file}" -w '%{http_code}' \
  -H 'X-Agent-Project: d16' \
  -H "X-Agent-Session: d16-v1-models-$$" \
  "http://127.0.0.1:${gate_port}/v1/models")"
[[ "${status_code}" == "200" ]] || {
  cat "${headers_file}" >&2 || true
  cat "${body_file}" >&2 || true
  fail "/v1/models must tolerate a failing secondary backend"
}

grep -qi '^x-gate-backend:[[:space:]]*ollama' "${headers_file}" \
  || fail "/v1/models should report ollama as the serving catalog backend when trtllm is unavailable"

python3 - "${body_file}" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1], "r", encoding="utf-8").read())
assert payload.get("object") == "list", payload
data = payload.get("data")
assert isinstance(data, list) and data, payload
ids = {item.get("id") for item in data if isinstance(item, dict)}
assert "mock-ollama:latest" in ids, ids
PY

ok "gate /v1/models ignores failing secondary catalog backends when at least one backend is healthy"
ok "D16_gate_models_partial_backend_failure passed"
