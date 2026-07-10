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
network_name="codex-d5-fixture-$$"
openai_mock_name="codex-d5-openai-$$"
openrouter_mock_name="codex-d5-openrouter-$$"
gate_name="codex-d5-gate-$$"
gate_port="$(pick_free_loopback_port 18060 100)"

cleanup() {
  docker rm -f "${gate_name}" "${openai_mock_name}" "${openrouter_mock_name}" >/dev/null 2>&1 || true
  docker network rm "${network_name}" >/dev/null 2>&1 || true
  rm -rf "${tmp_root}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p \
  "${tmp_root}/gate-config" \
  "${tmp_root}/gate-secrets" \
  "${tmp_root}/gate-state" \
  "${tmp_root}/gate-logs" \
  "${tmp_root}/provider-logs/openai" \
  "${tmp_root}/provider-logs/openrouter"

printf 'd5-openai-fixture-key\n' >"${tmp_root}/gate-secrets/openai.api_key"
printf 'd5-openrouter-fixture-key\n' >"${tmp_root}/gate-secrets/openrouter.api_key"
chmod 0600 "${tmp_root}/gate-secrets/openai.api_key" "${tmp_root}/gate-secrets/openrouter.api_key"

cat >"${tmp_root}/gate-config/model_routes.yml" <<'YAML'
version: 1

defaults:
  backend: openai

backends:
  openai:
    protocol: openai
    provider: openai
    base_url: http://OPENAI_MOCK_PLACEHOLDER:18082/v1
    api_key_file: /gate/secrets/openai.api_key
  openrouter:
    protocol: openai
    provider: openrouter
    base_url: http://OPENROUTER_MOCK_PLACEHOLDER:18083/v1
    api_key_file: /gate/secrets/openrouter.api_key

routes:
  - name: d5b-openai
    backend: openai
    match:
      - "d5-openai-mock"
  - name: d5b-openrouter
    backend: openrouter
    match:
      - "d5-openrouter-mock"
YAML
sed -i "s/OPENAI_MOCK_PLACEHOLDER/${openai_mock_name}/g" "${tmp_root}/gate-config/model_routes.yml"
sed -i "s/OPENROUTER_MOCK_PLACEHOLDER/${openrouter_mock_name}/g" "${tmp_root}/gate-config/model_routes.yml"

docker network create "${network_name}" >/dev/null

docker run -d \
  --name "${openai_mock_name}" \
  --network "${network_name}" \
  -v "${tmp_root}/provider-logs/openai:/logs" \
  --entrypoint python3 \
  agentic/ollama-gate:local \
  -u -c '
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path

LOG_PATH = Path("/logs/requests.jsonl")

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _write_json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        payload = json.loads(raw.decode("utf-8") or "{}")
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "http_referer": self.headers.get("HTTP-Referer"),
                "x_title": self.headers.get("X-Title"),
                "model": payload.get("model"),
            }) + "\n")
        self._write_json(200, {
            "id": "chatcmpl-openai-fixture",
            "object": "chat.completion",
            "created": 1780000000,
            "model": payload.get("model", "d5-openai-mock"),
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "openai fixture ok"},
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10}
        })

ThreadingHTTPServer(("0.0.0.0", 18082), Handler).serve_forever()
' >/dev/null

docker run -d \
  --name "${openrouter_mock_name}" \
  --network "${network_name}" \
  -v "${tmp_root}/provider-logs/openrouter:/logs" \
  --entrypoint python3 \
  agentic/ollama-gate:local \
  -u -c '
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path

LOG_PATH = Path("/logs/requests.jsonl")

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _write_json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        payload = json.loads(raw.decode("utf-8") or "{}")
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "http_referer": self.headers.get("HTTP-Referer"),
                "x_title": self.headers.get("X-Title"),
                "model": payload.get("model"),
            }) + "\n")
        self._write_json(200, {
            "id": "chatcmpl-openrouter-fixture",
            "object": "chat.completion",
            "created": 1780000001,
            "model": payload.get("model", "d5-openrouter-mock"),
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "openrouter fixture ok"},
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 8, "completion_tokens": 4, "total_tokens": 12}
        })

ThreadingHTTPServer(("0.0.0.0", 18083), Handler).serve_forever()
' >/dev/null

docker run -d \
  --name "${gate_name}" \
  --network "${network_name}" \
  -p "127.0.0.1:${gate_port}:11435" \
  -e GATE_MODEL_ROUTES_FILE=/gate/config/model_routes.yml \
  -e GATE_STATE_DIR=/gate/state \
  -e GATE_LOG_FILE=/gate/logs/gate.jsonl \
  -v "${tmp_root}/gate-config:/gate/config:ro" \
  -v "${tmp_root}/gate-secrets:/gate/secrets:ro" \
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
  || fail "ollama-gate fixture did not become ready on port ${gate_port}"

call_chat() {
  local session="$1"
  local model="$2"
  curl -sS \
    -H 'Content-Type: application/json' \
    -H "X-Agent-Session: ${session}" \
    -H 'X-Agent-Project: d5b' \
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"fixture provider check\"}]}" \
    -w '\n%{http_code}' \
    "http://127.0.0.1:${gate_port}/v1/chat/completions"
}

extract_code() {
  printf '%s\n' "$1" | tail -n 1 | tr -d '\r'
}

extract_body() {
  printf '%s\n' "$1" | sed '$d'
}

assert_gate_log_provider() {
  local session="$1"
  local expected_backend="$2"
  local expected_provider="$3"
  local line

  line="$(grep "\"session\":\"${session}\"" "${tmp_root}/gate-logs/gate.jsonl" | tail -n 1 || true)"
  [[ -n "${line}" ]] || fail "no gate log entry found for session ${session}"
  printf '%s\n' "${line}" | grep -q "\"backend\":\"${expected_backend}\"" \
    || fail "unexpected backend for session ${session}: ${line}"
  printf '%s\n' "${line}" | grep -q "\"provider\":\"${expected_provider}\"" \
    || fail "unexpected provider for session ${session}: ${line}"
}

assert_mock_log_headers() {
  local log_file="$1"
  local expected_bearer="$2"
  local require_openrouter_headers="$3"

  python3 - "${log_file}" "${expected_bearer}" "${require_openrouter_headers}" <<'PY'
import json
import sys
from pathlib import Path

log_file = Path(sys.argv[1])
expected_bearer = sys.argv[2]
require_openrouter_headers = sys.argv[3] == "1"

entries = [json.loads(line) for line in log_file.read_text(encoding="utf-8").splitlines() if line.strip()]
assert entries, f"mock log is empty: {log_file}"
entry = entries[-1]
assert entry["path"] == "/v1/chat/completions", entry
assert entry["authorization"] == expected_bearer, entry
if require_openrouter_headers:
    assert entry["http_referer"] == "https://localhost/agentic", entry
    assert entry["x_title"] == "DGX Spark Agentic Stack", entry
else:
    assert entry["http_referer"] in (None, ""), entry
    assert entry["x_title"] in (None, ""), entry
PY
}

openai_session="d5b-openai-$$"
openai_resp="$(call_chat "${openai_session}" "d5-openai-mock")"
openai_code="$(extract_code "${openai_resp}")"
openai_body="$(extract_body "${openai_resp}")"
[[ "${openai_code}" == "200" ]] || {
  printf '%s\n' "${openai_body}" >&2
  fail "fixture OpenAI routed request failed with status ${openai_code}"
}
printf '%s\n' "${openai_body}" | grep -q '"choices"' || fail "fixture OpenAI response is not usable"
printf '%s\n' "${openai_body}" | grep -q 'openai fixture ok' || fail "fixture OpenAI response content mismatch"
assert_gate_log_provider "${openai_session}" "openai" "openai"
assert_mock_log_headers "${tmp_root}/provider-logs/openai/requests.jsonl" "Bearer d5-openai-fixture-key" "0"
ok "fixture OpenAI backend routing is functional"

openrouter_session="d5b-openrouter-$$"
openrouter_resp="$(call_chat "${openrouter_session}" "d5-openrouter-mock")"
openrouter_code="$(extract_code "${openrouter_resp}")"
openrouter_body="$(extract_body "${openrouter_resp}")"
[[ "${openrouter_code}" == "200" ]] || {
  printf '%s\n' "${openrouter_body}" >&2
  fail "fixture OpenRouter routed request failed with status ${openrouter_code}"
}
printf '%s\n' "${openrouter_body}" | grep -q '"choices"' || fail "fixture OpenRouter response is not usable"
printf '%s\n' "${openrouter_body}" | grep -q 'openrouter fixture ok' || fail "fixture OpenRouter response content mismatch"
assert_gate_log_provider "${openrouter_session}" "openrouter" "openrouter"
assert_mock_log_headers "${tmp_root}/provider-logs/openrouter/requests.jsonl" "Bearer d5-openrouter-fixture-key" "1"
ok "fixture OpenRouter backend routing is functional"

grep -Fq 'd5-openai-fixture-key' "${tmp_root}/gate-logs/gate.jsonl" && fail "OpenAI fixture key leaked into gate logs"
grep -Fq 'd5-openrouter-fixture-key' "${tmp_root}/gate-logs/gate.jsonl" && fail "OpenRouter fixture key leaked into gate logs"
ok "fixture provider secrets are not present in gate logs"

ok "D5b_gate_external_providers_fixture passed"
