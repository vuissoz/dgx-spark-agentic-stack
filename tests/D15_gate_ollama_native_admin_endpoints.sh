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
network_name="codex-ollama-native-$$"
mock_name="codex-ollama-native-mock-$$"
gate_name="codex-ollama-native-gate-$$"

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
    base_url: http://codex-ollama-native-mock-PLACEHOLDER:18080
routes:
  - name: default-ollama
    backend: ollama
    match:
      - "mock-native"
YAML
sed -i "s/codex-ollama-native-mock-PLACEHOLDER/${mock_name}/g" "${tmp_root}/gate-config/model_routes.yml"

docker network create "${network_name}" >/dev/null

docker run -d \
  --name "${mock_name}" \
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

    def _read(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _json_response(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def _blob_digest(self):
        prefix = "/api/blobs/"
        if self.path.startswith(prefix):
            return self.path[len(prefix):]
        return ""

    def do_GET(self):
        if self.path == "/api/version":
            self._json_response(200, {"version": "mock"})
            return
        if self.path.startswith("/api/blobs/"):
            self._json_response(200, {"method": "GET", "path": self.path, "digest": self._blob_digest()})
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        if self.path.startswith("/api/blobs/"):
            self.send_response(200)
            self.send_header("X-Mock-Blob", self._blob_digest())
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self):
        if self.path != "/api/delete":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        raw = self._read()
        payload = json.loads(raw.decode("utf-8"))
        self._json_response(200, {"method": "DELETE", "path": self.path, "payload": payload})

    def do_POST(self):
        if self.path.startswith("/api/blobs/"):
            raw = self._read()
            self._json_response(
                200,
                {
                    "method": "POST",
                    "path": self.path,
                    "digest": self._blob_digest(),
                    "content_type": self.headers.get("Content-Type", ""),
                    "size": len(raw),
                },
            )
            return

        if self.path in {"/api/pull", "/api/push", "/api/create", "/api/copy", "/api/embed", "/api/embeddings"}:
            raw = self._read()
            payload = json.loads(raw.decode("utf-8"))
            self._json_response(200, {"method": "POST", "path": self.path, "payload": payload})
            return

        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


ThreadingHTTPServer(("0.0.0.0", 18080), Handler).serve_forever()
' >/dev/null

docker run -d \
  --name "${gate_name}" \
  --network "${network_name}" \
  -p 127.0.0.1:18037:11435 \
  -e OLLAMA_BASE_URL="http://${mock_name}:18080" \
  -e GATE_MODEL_ROUTES_FILE=/gate/config/model_routes.yml \
  -e GATE_STATE_DIR=/gate/state \
  -e GATE_LOG_FILE=/gate/logs/gate.jsonl \
  -v "${tmp_root}/gate-config:/gate/config:ro" \
  -v "${tmp_root}/gate-state:/gate/state" \
  -v "${tmp_root}/gate-logs:/gate/logs" \
  agentic/ollama-gate:local >/dev/null

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:18037/healthz >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

tmp_resp="$(mktemp)"
tmp_headers="$(mktemp)"
tmp_head_headers="$(mktemp)"
trap 'rm -f "${tmp_resp}" "${tmp_headers}" "${tmp_head_headers}" >/dev/null 2>&1 || true' RETURN

run_post_json() {
  local endpoint="$1"
  local payload="$2"
  local http_code
  http_code="$(curl -sS -D "${tmp_headers}" -o "${tmp_resp}" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    --data "${payload}" \
    "http://127.0.0.1:18037${endpoint}")"
  grep -qi '^x-gate-backend:[[:space:]]*ollama' "${tmp_headers}" \
    || { cat "${tmp_headers}" >&2 || true; cat "${tmp_resp}" >&2 || true; fail "${endpoint}: missing X-Gate-Backend: ollama header (status=${http_code})"; }
}

run_post_json "/api/pull" '{"name":"mock-native","stream":false}'
python3 - "${tmp_resp}" <<'PY'
import json, sys
payload = json.loads(open(sys.argv[1], "r", encoding="utf-8").read())
assert payload["path"] == "/api/pull", payload
assert payload["payload"]["name"] == "mock-native", payload
PY

run_post_json "/api/push" '{"name":"mock-native","stream":false}'
python3 - "${tmp_resp}" <<'PY'
import json, sys
payload = json.loads(open(sys.argv[1], "r", encoding="utf-8").read())
assert payload["path"] == "/api/push", payload
assert payload["payload"]["name"] == "mock-native", payload
PY

run_post_json "/api/create" '{"model":"mock-native","modelfile":"FROM mock-native"}'
python3 - "${tmp_resp}" <<'PY'
import json, sys
payload = json.loads(open(sys.argv[1], "r", encoding="utf-8").read())
assert payload["path"] == "/api/create", payload
assert payload["payload"]["model"] == "mock-native", payload
PY

run_post_json "/api/copy" '{"source":"mock-native","destination":"mock-native-copy"}'
python3 - "${tmp_resp}" <<'PY'
import json, sys
payload = json.loads(open(sys.argv[1], "r", encoding="utf-8").read())
assert payload["path"] == "/api/copy", payload
assert payload["payload"]["source"] == "mock-native", payload
PY

run_post_json "/api/embed" '{"model":"mock-native","input":"hello"}'
python3 - "${tmp_resp}" <<'PY'
import json, sys
payload = json.loads(open(sys.argv[1], "r", encoding="utf-8").read())
assert payload["path"] == "/api/embed", payload
assert payload["payload"]["model"] == "mock-native", payload
PY

curl -sS -D "${tmp_headers}" -o "${tmp_resp}" \
  -X DELETE \
  -H 'Content-Type: application/json' \
  --data '{"name":"mock-native"}' \
  "http://127.0.0.1:18037/api/delete"
grep -qi '^x-gate-backend: ollama' "${tmp_headers}" \
  || fail "/api/delete: missing X-Gate-Backend: ollama header"
python3 - "${tmp_resp}" <<'PY'
import json, sys
payload = json.loads(open(sys.argv[1], "r", encoding="utf-8").read())
assert payload["method"] == "DELETE", payload
assert payload["path"] == "/api/delete", payload
assert payload["payload"]["name"] == "mock-native", payload
PY

curl -sS -D "${tmp_headers}" -o "${tmp_resp}" \
  "http://127.0.0.1:18037/api/blobs/sha256:abc123"
grep -qi '^x-gate-backend: ollama' "${tmp_headers}" \
  || fail "/api/blobs GET: missing X-Gate-Backend: ollama header"
python3 - "${tmp_resp}" <<'PY'
import json, sys
payload = json.loads(open(sys.argv[1], "r", encoding="utf-8").read())
assert payload["method"] == "GET", payload
assert payload["path"] == "/api/blobs/sha256:abc123", payload
PY

curl -sS -D "${tmp_head_headers}" -I "http://127.0.0.1:18037/api/blobs/sha256:abc123" >/dev/null
grep -qi '^x-gate-backend: ollama' "${tmp_head_headers}" \
  || fail "/api/blobs HEAD: missing X-Gate-Backend: ollama header"

curl -sS -D "${tmp_headers}" -o "${tmp_resp}" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary 'blob-payload' \
  "http://127.0.0.1:18037/api/blobs/sha256:abc123"
grep -qi '^x-gate-backend: ollama' "${tmp_headers}" \
  || fail "/api/blobs POST: missing X-Gate-Backend: ollama header"
python3 - "${tmp_resp}" <<'PY'
import json, sys
payload = json.loads(open(sys.argv[1], "r", encoding="utf-8").read())
assert payload["method"] == "POST", payload
assert payload["path"] == "/api/blobs/sha256:abc123", payload
assert payload["content_type"] == "application/octet-stream", payload
assert payload["size"] == len(b"blob-payload"), payload
PY

ok "gate proxies native Ollama admin endpoints (/api/pull|push|create|delete|copy|blobs|embed)"
