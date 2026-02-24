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

session="h1-openwebui-$RANDOM-$$"
timeout 20 docker exec "${openwebui_cid}" sh -lc "python3 - <<'PY'
import json
import urllib.request

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
PY" || fail "openwebui container failed to call ollama-gate"

gate_log="${AGENTIC_ROOT:-/srv/agentic}/gate/logs/gate.jsonl"
[[ -s "${gate_log}" ]] || fail "gate log file missing or empty: ${gate_log}"
grep -q "\"session\":\"${session}\"" "${gate_log}" \
  || fail "gate logs do not contain the openwebui smoke session"
ok "openwebui-to-gate traffic is visible in gate logs"

ok "H1_openwebui passed"
