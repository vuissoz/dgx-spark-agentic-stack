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
ok "openhands model/api key env is present"

session="h2-openhands-$RANDOM-$$"
timeout 20 docker exec "${openhands_cid}" sh -lc "python3 - <<'PY'
import json
import urllib.request

payload = {
  'model': 'h2-openhands-model',
  'messages': [{'role': 'user', 'content': 'openhands gate smoke'}]
}
req = urllib.request.Request(
  'http://ollama-gate:11435/v1/chat/completions',
  data=json.dumps(payload).encode('utf-8'),
  headers={
    'Content-Type': 'application/json',
    'X-Agent-Session': '${session}',
    'X-Agent-Project': 'openhands',
    'X-Gate-Dry-Run': '1',
  },
  method='POST'
)
with urllib.request.urlopen(req, timeout=10) as resp:
  if resp.status != 200:
    raise SystemExit(1)
PY" || fail "openhands container failed to call ollama-gate"

gate_log="${AGENTIC_ROOT:-/srv/agentic}/gate/logs/gate.jsonl"
[[ -s "${gate_log}" ]] || fail "gate log file missing or empty: ${gate_log}"
grep -q "\"session\":\"${session}\"" "${gate_log}" \
  || fail "gate logs do not contain the openhands smoke session"
ok "openhands-to-gate traffic is visible in gate logs"

ok "H2_openhands passed"
