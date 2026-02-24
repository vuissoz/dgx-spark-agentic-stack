#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_D_TESTS:-0}" == "1" ]]; then
  ok "D7 skipped because AGENTIC_SKIP_D_TESTS=1"
  exit 0
fi

assert_cmd python3

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
model_routes_file="${agentic_root}/gate/config/model_routes.yml"
mode_file="${agentic_root}/gate/state/llm_mode.json"
quota_file="${agentic_root}/gate/state/quotas_state.json"
gate_log="${agentic_root}/gate/logs/gate.jsonl"
mcp_audit_log="${agentic_root}/gate/mcp/logs/audit.jsonl"
openai_key_file="${agentic_root}/secrets/runtime/openai.api_key"

[[ -f "${model_routes_file}" ]] || fail "model routes file missing: ${model_routes_file}"

toolbox_cid="$(require_service_container toolbox)"
gate_cid="$(require_service_container ollama-gate)"
gate_mcp_cid="$(require_service_container gate-mcp)"

wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate is not ready"
wait_for_container_ready "${gate_mcp_cid}" 120 || fail "gate-mcp is not ready"

agent_cid="$(service_container_id agentic-codex || true)"
if [[ -z "${agent_cid}" ]]; then
  "${agent_bin}" up agents >/tmp/agent-d7-up-agents.out \
    || fail "unable to start agents stack required for D7"
  agent_cid="$(require_service_container agentic-codex)"
fi
wait_for_container_ready "${agent_cid}" 90 || fail "agentic-codex is not ready"

env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${agent_cid}" 2>/dev/null || true)"
echo "${env_dump}" | grep -q '^GATE_MCP_URL=http://gate-mcp:8123$' \
  || fail "agent container must expose GATE_MCP_URL"
echo "${env_dump}" | grep -q '^GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token$' \
  || fail "agent container must expose GATE_MCP_AUTH_TOKEN_FILE"

routes_backup="$(mktemp)"
mode_backup="$(mktemp)"
quota_backup="$(mktemp)"
mode_had_file=0
quota_had_file=0

cp "${model_routes_file}" "${routes_backup}"
if [[ -f "${mode_file}" ]]; then
  cp "${mode_file}" "${mode_backup}"
  mode_had_file=1
fi
if [[ -f "${quota_file}" ]]; then
  cp "${quota_file}" "${quota_backup}"
  quota_had_file=1
fi

ollama_cid="$(service_container_id ollama || true)"
trt_cid="$(service_container_id trtllm || true)"
ollama_was_running=0
trt_was_running=0

if [[ -n "${ollama_cid}" ]]; then
  [[ "$(docker inspect --format '{{.State.Status}}' "${ollama_cid}" 2>/dev/null || true)" == "running" ]] && ollama_was_running=1
fi
if [[ -n "${trt_cid}" ]]; then
  [[ "$(docker inspect --format '{{.State.Status}}' "${trt_cid}" 2>/dev/null || true)" == "running" ]] && trt_was_running=1
fi

restore() {
  cp "${routes_backup}" "${model_routes_file}" || true
  chmod 0640 "${model_routes_file}" || true
  rm -f "${routes_backup}" || true

  if [[ "${mode_had_file}" == "1" ]]; then
    cp "${mode_backup}" "${mode_file}" || true
    chmod 0640 "${mode_file}" || true
  else
    rm -f "${mode_file}" || true
  fi
  rm -f "${mode_backup}" || true

  if [[ "${quota_had_file}" == "1" ]]; then
    cp "${quota_backup}" "${quota_file}" || true
    chmod 0640 "${quota_file}" || true
  else
    rm -f "${quota_file}" || true
  fi
  rm -f "${quota_backup}" || true

  if [[ -n "${gate_cid:-}" ]]; then
    docker restart "${gate_cid}" >/dev/null 2>&1 || true
    wait_for_container_ready "${gate_cid}" 120 || true
  fi
  if [[ -n "${gate_mcp_cid:-}" ]]; then
    docker restart "${gate_mcp_cid}" >/dev/null 2>&1 || true
    wait_for_container_ready "${gate_mcp_cid}" 120 || true
  fi

  if [[ -n "${ollama_cid:-}" ]]; then
    if [[ "${ollama_was_running}" == "1" ]]; then
      docker start "${ollama_cid}" >/dev/null 2>&1 || true
      wait_for_container_ready "${ollama_cid}" 120 || true
    else
      docker stop "${ollama_cid}" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "${trt_cid:-}" ]]; then
    if [[ "${trt_was_running}" == "1" ]]; then
      docker start "${trt_cid}" >/dev/null 2>&1 || true
      wait_for_container_ready "${trt_cid}" 120 || true
    else
      docker stop "${trt_cid}" >/dev/null 2>&1 || true
    fi
  fi
}
trap restore EXIT

cat >"${model_routes_file}" <<'YAML'
version: 1

defaults:
  backend: ollama

llm:
  default_mode: hybrid

quotas:
  providers:
    openai:
      daily_tokens: 8
      monthly_tokens: 50
      daily_requests: 10
      monthly_requests: 30

backends:
  ollama:
    protocol: ollama
    base_url: http://ollama:11434
  trtllm:
    protocol: ollama
    base_url: http://trtllm:11436
  openai:
    protocol: openai
    provider: openai
    base_url: https://api.openai.com/v1
    api_key_file: /gate/secrets/openai.api_key

routes:
  - name: d7-openai
    backend: openai
    match:
      - "d7-remote-*"
YAML
chmod 0640 "${model_routes_file}" || true

install -d -m 0700 "${agentic_root}/secrets/runtime"
if [[ ! -s "${openai_key_file}" ]]; then
  printf 'd7-test-key\n' >"${openai_key_file}"
  chmod 0600 "${openai_key_file}"
fi

rm -f "${quota_file}" || true
"${agent_bin}" llm mode hybrid >/tmp/agent-d7-hybrid.out
docker restart "${gate_cid}" >/dev/null
wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate did not become healthy after D7 route reload"
docker restart "${gate_mcp_cid}" >/dev/null
wait_for_container_ready "${gate_mcp_cid}" 120 || fail "gate-mcp did not become healthy after gate reload"

call_chat() {
  local session="$1"
  local model="$2"
  local tokens="${3:-1}"
  timeout 25 docker exec "${toolbox_cid}" sh -lc "curl -sS -H 'Content-Type: application/json' -H 'X-Agent-Session: ${session}' -H 'X-Agent-Project: d7' -H 'X-Gate-Dry-Run: 1' -H 'X-Gate-Test-Tokens: ${tokens}' -d '{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"d7 mcp test\"}]}' http://ollama-gate:11435/v1/chat/completions -w '\n%{http_code}'"
}

call_mcp_from_agent() {
  local payload="$1"
  timeout 20 docker exec -e MCP_PAYLOAD="${payload}" "${agent_cid}" sh -lc \
    'token=$(cat "${GATE_MCP_AUTH_TOKEN_FILE:-/run/secrets/gate_mcp.token}"); curl -sS -H "Content-Type: application/json" -H "Authorization: Bearer ${token}" -d "${MCP_PAYLOAD}" "${GATE_MCP_URL:-http://gate-mcp:8123}/v1/tools/execute" -w "\n%{http_code}"'
}

call_mcp_tools_list_from_agent() {
  timeout 20 docker exec "${agent_cid}" sh -lc \
    'token=$(cat "${GATE_MCP_AUTH_TOKEN_FILE:-/run/secrets/gate_mcp.token}"); curl -sS -H "Authorization: Bearer ${token}" "${GATE_MCP_URL:-http://gate-mcp:8123}/v1/tools/list" -w "\n%{http_code}"'
}

extract_code() {
  printf '%s\n' "$1" | tail -n 1 | tr -d '\r'
}

extract_body() {
  printf '%s\n' "$1" | sed '$d'
}

json_read() {
  local body="$1"
  local path="$2"
  python3 - "${path}" "${body}" <<'PY'
import json
import sys

path = sys.argv[1].split(".")
raw = sys.argv[2]
try:
    value = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)

for key in path:
    if isinstance(value, dict) and key in value:
        value = value[key]
    else:
        print("")
        raise SystemExit(0)

if isinstance(value, (dict, list)):
    print(json.dumps(value))
elif value is None:
    print("")
else:
    print(value)
PY
}

session_local="d7-local-$$"
chat_resp="$(call_chat "${session_local}" "d7-local-a")"
chat_code="$(extract_code "${chat_resp}")"
[[ "${chat_code}" == "200" ]] || fail "initial local chat call failed for D7"

payload_current="$(printf '{"tool":"gate.current_model","args":{"session_id":"%s","project":"d7"}}' "${session_local}")"
resp_current="$(call_mcp_from_agent "${payload_current}")"
code_current="$(extract_code "${resp_current}")"
body_current="$(extract_body "${resp_current}")"
[[ "${code_current}" == "200" ]] || {
  printf '%s\n' "${body_current}" >&2
  fail "MCP gate.current_model must return 200"
}

current_model="$(json_read "${body_current}" "model_served")"
current_backend="$(json_read "${body_current}" "backend")"
current_provider="$(json_read "${body_current}" "provider")"
[[ -n "${current_model}" ]] || fail "MCP gate.current_model returned an empty model_served"
[[ "${current_model}" == "d7-local-a" ]] || fail "MCP current_model mismatch (expected d7-local-a, got ${current_model})"
[[ -n "${current_backend}" && -n "${current_provider}" ]] \
  || fail "MCP current_model must include backend and provider"
ok "MCP gate.current_model returns served model/backend/provider from agent container"

resp_tools_list="$(call_mcp_tools_list_from_agent)"
code_tools_list="$(extract_code "${resp_tools_list}")"
body_tools_list="$(extract_body "${resp_tools_list}")"
[[ "${code_tools_list}" == "200" ]] || fail "MCP tools list endpoint must return 200"
echo "${body_tools_list}" | grep -q '"name":"gate.current_model"' \
  || fail "MCP tools list must include gate.current_model"
echo "${body_tools_list}" | grep -q '"name":"gate.quota_remaining"' \
  || fail "MCP tools list must include gate.quota_remaining"
echo "${body_tools_list}" | grep -q '"name":"gate.switch_model"' \
  || fail "MCP tools list must include gate.switch_model"
ok "MCP tools list advertises all D7 gate tools"

payload_quota='{"tool":"gate.quota_remaining","args":{"project":"d7"}}'
resp_quota="$(call_mcp_from_agent "${payload_quota}")"
code_quota="$(extract_code "${resp_quota}")"
body_quota="$(extract_body "${resp_quota}")"
[[ "${code_quota}" == "200" ]] || {
  printf '%s\n' "${body_quota}" >&2
  fail "MCP gate.quota_remaining must return 200"
}
quota_before="$(json_read "${body_quota}" "providers.openai.remaining_daily_tokens")"
[[ -n "${quota_before}" ]] || fail "MCP gate.quota_remaining must expose providers.openai.remaining_daily_tokens"
ok "MCP gate.quota_remaining exposes provider counters"

payload_switch="$(printf '{"tool":"gate.switch_model","args":{"session_id":"%s","model":"d7-local-b","project":"d7"}}' "${session_local}")"
resp_switch="$(call_mcp_from_agent "${payload_switch}")"
code_switch="$(extract_code "${resp_switch}")"
body_switch="$(extract_body "${resp_switch}")"
[[ "${code_switch}" == "200" ]] || {
  printf '%s\n' "${body_switch}" >&2
  fail "MCP gate.switch_model must return 200"
}
switched_model="$(json_read "${body_switch}" "model_served")"
[[ "${switched_model}" == "d7-local-b" ]] || fail "MCP gate.switch_model must set sticky model to d7-local-b"

resp_current_after="$(call_mcp_from_agent "${payload_current}")"
code_current_after="$(extract_code "${resp_current_after}")"
body_current_after="$(extract_body "${resp_current_after}")"
[[ "${code_current_after}" == "200" ]] || fail "MCP gate.current_model after switch must return 200"
current_after_model="$(json_read "${body_current_after}" "model_served")"
[[ "${current_after_model}" == "d7-local-b" ]] || fail "sticky model did not update after MCP switch"

grep "\"session\":\"${session_local}\"" "${gate_log}" | tail -n 20 | grep -q '"model_switch":true' \
  || fail "gate log must include model_switch=true after MCP switch"
ok "MCP gate.switch_model updates sticky model and leaves gate audit trace"

"${agent_bin}" llm mode remote >/tmp/agent-d7-remote.out
if [[ -n "${ollama_cid}" ]]; then
  docker stop "${ollama_cid}" >/dev/null || true
fi
if [[ -n "${trt_cid}" ]]; then
  docker stop "${trt_cid}" >/dev/null || true
fi

session_remote="d7-remote-$$"
remote_chat_resp="$(call_chat "${session_remote}" "d7-remote-model" 2)"
remote_chat_code="$(extract_code "${remote_chat_resp}")"
[[ "${remote_chat_code}" == "200" ]] || fail "remote provider-routed request must succeed in remote mode"

payload_remote_current="$(printf '{"tool":"gate.current_model","args":{"session_id":"%s","project":"d7"}}' "${session_remote}")"
resp_remote_current="$(call_mcp_from_agent "${payload_remote_current}")"
code_remote_current="$(extract_code "${resp_remote_current}")"
body_remote_current="$(extract_body "${resp_remote_current}")"
[[ "${code_remote_current}" == "200" ]] || fail "MCP gate.current_model must work in remote mode with local backends stopped"

remote_provider="$(json_read "${body_remote_current}" "provider")"
remote_backend="$(json_read "${body_remote_current}" "backend")"
[[ "${remote_provider}" == "openai" && "${remote_backend}" == "openai" ]] \
  || fail "MCP current_model should reflect external provider routing in remote mode"
ok "MCP remains coherent in remote mode with local backends stopped"

resp_quota_after="$(call_mcp_from_agent "${payload_quota}")"
code_quota_after="$(extract_code "${resp_quota_after}")"
body_quota_after="$(extract_body "${resp_quota_after}")"
[[ "${code_quota_after}" == "200" ]] || fail "MCP gate.quota_remaining after remote call must return 200"
quota_after="$(json_read "${body_quota_after}" "providers.openai.remaining_daily_tokens")"
[[ -n "${quota_after}" ]] || fail "quota remaining after remote request is missing"
(( quota_after < quota_before )) || fail "quota remaining must decrease after external provider call"
ok "MCP quota counters reflect external usage"

unauth_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/d7-mcp-unauth.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{\"tool\":\"gate.current_model\",\"args\":{\"session_id\":\"${session_local}\"}}' http://gate-mcp:8123/v1/tools/execute")"
[[ "${unauth_status}" == "401" ]] || fail "gate-mcp must reject unauthorized access"
assert_no_public_bind 8123 || fail "gate-mcp must not be exposed on a host non-loopback listener"
ok "gate-mcp denies unauthorized calls and remains internal-only"

[[ -s "${mcp_audit_log}" ]] || fail "MCP audit log must exist and be non-empty: ${mcp_audit_log}"
audit_check="$(python3 - "${mcp_audit_log}" <<'PY'
import json
import sys

path = sys.argv[1]
has_allow = False
has_unauthorized = False

with open(path, "r", encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            row.get("module") == "gate-mcp"
            and row.get("action") == "execute_tool"
            and row.get("tool") == "gate.current_model"
            and row.get("decision") == "allow"
        ):
            has_allow = True
        if row.get("module") == "gate-mcp" and row.get("reason") == "unauthorized":
            has_unauthorized = True

print("ok" if (has_allow and has_unauthorized) else "missing")
PY
)"
[[ "${audit_check}" == "ok" ]] \
  || fail "MCP audit log must contain both allow traces and unauthorized deny traces"
ok "MCP audit log captures allowed and unauthorized requests"

ok "D7_local_mcp_gate_visibility passed"
