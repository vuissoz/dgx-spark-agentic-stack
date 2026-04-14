#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_H_TESTS:-0}" == "1" ]]; then
  ok "H1 skipped because AGENTIC_SKIP_H_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd curl

openwebui_port="${OPENWEBUI_HOST_PORT:-8080}"
openwebui_cid="$(require_service_container openwebui)" || exit 1
gate_cid="$(require_service_container ollama-gate)" || exit 1

wait_for_container_ready "${openwebui_cid}" 180 || fail "openwebui is not ready"
wait_for_container_ready "${gate_cid}" 90 || fail "ollama-gate is not ready"

assert_no_public_bind "${openwebui_port}" || fail "openwebui host bind is not loopback-only"
ok "openwebui host bind is loopback-only"

onboarding_payload="$(curl -fsS --max-time 10 "http://127.0.0.1:${openwebui_port}/api/config" | tr -d '[:space:]' || true)"
[[ "${onboarding_payload}" != *"\"onboarding\":true"* ]] \
  || fail "openwebui onboarding is still enabled; verify WEBUI_ADMIN_EMAIL/WEBUI_ADMIN_PASSWORD in openwebui.env"
ok "openwebui onboarding is disabled after admin bootstrap"

auth_ok=0
for endpoint in \
  "/api/v1/users/user/info" \
  "/api/v1/chats/" \
  "/api/v1/auths/api_key"; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${openwebui_port}${endpoint}" || true)"
  if [[ "${code}" == "401" || "${code}" == "403" ]]; then
    auth_ok=1
    break
  fi
done
[[ "${auth_ok}" -eq 1 ]] || fail "openwebui unauthenticated access is not explicitly denied (expected 401/403 on protected endpoint)"
ok "openwebui protected endpoint rejects unauthenticated access"

openwebui_env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${openwebui_cid}" 2>/dev/null || true)"
openai_api_base_url="$(printf '%s\n' "${openwebui_env_dump}" | sed -n 's/^OPENAI_API_BASE_URL=//p' | head -n 1)"
enable_ollama_api_raw="$(printf '%s\n' "${openwebui_env_dump}" | sed -n 's/^ENABLE_OLLAMA_API=//p' | head -n 1)"
ollama_base_url="$(printf '%s\n' "${openwebui_env_dump}" | sed -n 's/^OLLAMA_BASE_URL=//p' | head -n 1)"

[[ "${openai_api_base_url}" == "http://ollama-gate:11435/v1" ]] \
  || fail "openwebui OPENAI_API_BASE_URL must be pinned to gate (/v1), got: ${openai_api_base_url:-<unset>}"

case "${enable_ollama_api_raw,,}" in
  0|false|no|off|"")
    [[ "${ollama_base_url}" == "http://ollama-gate:11435" ]] \
      || fail "openwebui gate-only mode must keep OLLAMA_BASE_URL=http://ollama-gate:11435 when ENABLE_OLLAMA_API is disabled (got: ${ollama_base_url:-<unset>})"
    ;;
  1|true|yes|on)
    [[ "${ollama_base_url}" == "http://ollama:11434" || "${ollama_base_url}" == "http://ollama-gate:11435" ]] \
      || fail "openwebui ENABLE_OLLAMA_API=true must use OLLAMA_BASE_URL=http://ollama:11434 (direct opt-in) or http://ollama-gate:11435 (gate-only), got: ${ollama_base_url:-<unset>}"
    ;;
  *)
    fail "openwebui has invalid ENABLE_OLLAMA_API value: ${enable_ollama_api_raw:-<unset>}"
    ;;
esac
ok "openwebui runtime OpenAI/Ollama routing env is coherent"

gate_env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${gate_cid}" 2>/dev/null || true)"
gate_test_mode_raw="$(printf '%s\n' "${gate_env_dump}" | sed -n 's/^GATE_ENABLE_TEST_MODE=//p' | head -n 1)"

session="h1-openwebui-$RANDOM-$$"
case "${gate_test_mode_raw,,}" in
  1|true|yes|on)
    timeout 20 docker exec "${openwebui_cid}" sh -lc "python3 - <<'PY'
import json
import urllib.request

switch_req = urllib.request.Request(
  'http://ollama-gate:11435/admin/sessions/${session}/switch',
  data=json.dumps({'model': 'h1-stale-model'}).encode('utf-8'),
  headers={'Content-Type': 'application/json', 'X-Agent-Project': 'openwebui'},
  method='POST'
)
with urllib.request.urlopen(switch_req, timeout=10) as resp:
  if resp.status != 200:
    raise SystemExit(1)

payload = {
  'model': 'h1-openwebui-model',
  'messages': [{'role': 'user', 'content': 'openwebui gate smoke'}]
}
req = urllib.request.Request(
  'http://ollama-gate:11435/v1/chat/completions',
  data=json.dumps(payload).encode('utf-8'),
  headers={
    'Content-Type': 'application/json',
    'X-Agent-Session': '${session}',
    'X-Agent-Project': 'openwebui',
    'X-Gate-Dry-Run': '1',
  },
  method='POST'
)
with urllib.request.urlopen(req, timeout=10) as resp:
  if resp.status != 200:
    raise SystemExit(1)
  body = json.loads(resp.read().decode('utf-8'))
  if body.get('model') != 'h1-openwebui-model':
    raise SystemExit(f\"explicit OpenWebUI model was not served: {body.get('model')}\")
PY" || fail "openwebui container failed to call ollama-gate /v1/chat/completions in dry-run mode"
    ;;
  *)
    timeout 20 docker exec "${openwebui_cid}" sh -lc "python3 - <<'PY'
import urllib.request

req = urllib.request.Request(
  'http://ollama-gate:11435/api/version',
  headers={
    'X-Agent-Session': '${session}',
    'X-Agent-Project': 'openwebui',
  },
  method='GET'
)
with urllib.request.urlopen(req, timeout=10) as resp:
  if resp.status != 200:
    raise SystemExit(1)
PY" || fail "openwebui container failed to call ollama-gate /api/version"
    ;;
esac

gate_log="${AGENTIC_ROOT:-/srv/agentic}/gate/logs/gate.jsonl"
[[ -s "${gate_log}" ]] || fail "gate log file missing or empty: ${gate_log}"
grep -q "\"session\":\"${session}\"" "${gate_log}" \
  || fail "gate logs do not contain the openwebui smoke session"
ok "openwebui-to-gate traffic is visible in gate logs"

ok "H1_openwebui passed"
