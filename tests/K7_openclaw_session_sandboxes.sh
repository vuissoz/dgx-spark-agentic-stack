#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K7 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd curl
assert_cmd python3

json_field() {
  local payload="$1"
  local field="$2"
  python3 - "${payload}" "${field}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
field = sys.argv[2]
value = payload
for part in field.split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
if value is None:
    raise SystemExit(1)
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

post_tool_execute() {
  local toolbox_cid="$1"
  local token="$2"
  local session_id="$3"
  local model="$4"
  local message="$5"
  docker exec "${toolbox_cid}" sh -lc "curl -fsS -X POST \
    -H 'Authorization: Bearer ${token}' \
    -H 'Content-Type: application/json' \
    -d '{\"session_id\":\"${session_id}\",\"model\":\"${model}\",\"tool\":\"diagnostics.echo\",\"args\":{\"message\":\"${message}\"}}' \
    http://openclaw:8111/v1/tools/execute"
}

sandbox_status_payload() {
  local toolbox_cid="$1"
  local token="$2"
  docker exec "${toolbox_cid}" sh -lc "curl -fsS -H 'Authorization: Bearer ${token}' http://openclaw-sandbox:8112/v1/sandboxes/status"
}

wait_for_active_sandboxes() {
  local toolbox_cid="$1"
  local token="$2"
  local expected="$3"
  local timeout_sec="${4:-20}"
  local elapsed=0
  local payload active

  while (( elapsed < timeout_sec )); do
    payload="$(sandbox_status_payload "${toolbox_cid}" "${token}" || true)"
    if [[ -n "${payload}" ]]; then
      active="$(json_field "${payload}" "active" || true)"
      if [[ "${active}" =~ ^[0-9]+$ ]] && (( active == expected )); then
        return 0
      fi
    fi
    sleep 1
    ((elapsed += 1))
  done

  fail "active sandbox count did not reach ${expected} within ${timeout_sec}s"
}

"${agent_bin}" down core >/tmp/agent-k7-down-pre.out 2>&1 || true
"${REPO_ROOT}/deployments/core/init_runtime.sh"

agentic_root="${AGENTIC_ROOT}"
install -d -m 0700 "${agentic_root}/secrets/runtime"

cat >"${agentic_root}/openclaw/config/tool_allowlist.txt" <<'ALLOW'
diagnostics.echo
ALLOW
chmod 0644 "${agentic_root}/openclaw/config/tool_allowlist.txt"

claw_token="k7-test-token-$(date +%s)"
printf '%s\n' "${claw_token}" >"${agentic_root}/secrets/runtime/openclaw.token"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.token"

webhook_secret="k7-webhook-secret-$(date +%s)"
printf '%s\n' "${webhook_secret}" >"${agentic_root}/secrets/runtime/openclaw.webhook_secret"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.webhook_secret"

if [[ "${EUID}" -eq 0 ]]; then
  chown "${AGENT_RUNTIME_UID:-1000}:${AGENT_RUNTIME_GID:-1000}" \
    "${agentic_root}/secrets/runtime/openclaw.token" \
    "${agentic_root}/secrets/runtime/openclaw.webhook_secret"
fi

OPENCLAW_SANDBOX_SESSION_TTL_SEC=4 \
OPENCLAW_SANDBOX_REAP_INTERVAL_SEC=1 \
"${agent_bin}" up core >/tmp/agent-k7-up.out \
  || fail "agent up core (openclaw session sandboxes) failed"

openclaw_cid="$(require_service_container openclaw)" || exit 1
sandbox_cid="$(require_service_container openclaw-sandbox)" || exit 1
toolbox_cid="$(require_service_container toolbox)" || exit 1

wait_for_container_ready "${openclaw_cid}" 90 || fail "openclaw did not become ready"
wait_for_container_ready "${sandbox_cid}" 90 || fail "openclaw-sandbox did not become ready"

response_same_1="$(post_tool_execute "${toolbox_cid}" "${claw_token}" "alpha" "qwen3-coder:30b" "hello-alpha-1")" \
  || fail "first session/model request failed"
response_same_2="$(post_tool_execute "${toolbox_cid}" "${claw_token}" "alpha" "qwen3-coder:30b" "hello-alpha-2")" \
  || fail "second session/model request failed"
response_other_model="$(post_tool_execute "${toolbox_cid}" "${claw_token}" "alpha" "qwen3-coder:14b" "hello-alpha-other-model")" \
  || fail "same session different model request failed"
response_other_session="$(post_tool_execute "${toolbox_cid}" "${claw_token}" "beta" "qwen3-coder:30b" "hello-beta")" \
  || fail "different session request failed"

same_1_sandbox_id="$(json_field "${response_same_1}" "sandbox_id")" || fail "sandbox_id missing in first response"
same_2_sandbox_id="$(json_field "${response_same_2}" "sandbox_id")" || fail "sandbox_id missing in second response"
other_model_sandbox_id="$(json_field "${response_other_model}" "sandbox_id")" || fail "sandbox_id missing in other-model response"
other_session_sandbox_id="$(json_field "${response_other_session}" "sandbox_id")" || fail "sandbox_id missing in other-session response"

[[ "${same_1_sandbox_id}" == "${same_2_sandbox_id}" ]] \
  || fail "same session/model must reuse the same sandbox"
[[ "${same_1_sandbox_id}" != "${other_model_sandbox_id}" ]] \
  || fail "same session with different model must allocate a different sandbox"
[[ "${same_1_sandbox_id}" != "${other_session_sandbox_id}" ]] \
  || fail "different session must allocate a different sandbox"

[[ "$(json_field "${response_same_1}" "sandbox_reused")" == "false" ]] \
  || fail "first lease should create a new sandbox"
[[ "$(json_field "${response_same_2}" "sandbox_reused")" == "true" ]] \
  || fail "second lease for same session/model should reuse sandbox"

wait_for_active_sandboxes "${toolbox_cid}" "${claw_token}" 3 20
status_payload="$(sandbox_status_payload "${toolbox_cid}" "${claw_token}")" \
  || fail "sandbox status endpoint failed"
[[ "$(json_field "${status_payload}" "default_model")" == "${AGENTIC_DEFAULT_MODEL:-qwen3-coder:30b}" ]] \
  || fail "sandbox status must expose default model"

ls_output="$("${agent_bin}" ls)"
printf '%s\n' "${ls_output}" | grep -q '^tool' || fail "agent ls output is missing header"
printf '%s\n' "${ls_output}" | grep -Eq '^openclaw.*sandboxes=3$' \
  || fail "agent ls must expose active openclaw sandbox count"

wait_for_active_sandboxes "${toolbox_cid}" "${claw_token}" 0 20
status_after_expire="$(sandbox_status_payload "${toolbox_cid}" "${claw_token}")" \
  || fail "sandbox status endpoint failed after expiration wait"
recent_expired_len="$(python3 - "${status_after_expire}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
recent = payload.get("recent_expired") or []
print(len(recent))
PY
)"
[[ "${recent_expired_len}" =~ ^[0-9]+$ ]] && (( recent_expired_len >= 3 )) \
  || fail "sandbox status must retain recent expired entries"

registry_file="${agentic_root}/openclaw/sandbox/state/session-sandboxes.json"
[[ -s "${registry_file}" ]] || fail "sandbox registry file missing: ${registry_file}"
registry_active="$(python3 - "${registry_file}" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(len(payload.get("sandboxes") or {}))
PY
)"
[[ "${registry_active}" == "0" ]] || fail "sandbox registry must be empty after TTL expiration"

audit_log="${agentic_root}/openclaw/logs/audit.jsonl"
grep -q '"action":"lease_sandbox"' "${audit_log}" || fail "audit log must include sandbox lease actions"
grep -q '"action":"sandbox_expire"' "${audit_log}" || fail "audit log must include sandbox expiration actions"

ok "K7_openclaw_session_sandboxes passed"
