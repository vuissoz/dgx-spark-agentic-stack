#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K8 skipped because AGENTIC_SKIP_K_TESTS=1"
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
value = payload
for part in sys.argv[2].split("."):
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

curl_json_status() {
  local output_file="$1"
  shift
  curl -sS -o "${output_file}" -w '%{http_code}' "$@"
}

approval_items_json() {
  "${agent_bin}" openclaw approvals list --json
}

approval_count() {
  local payload="$1"
  local status_name="$2"
  python3 - "${payload}" "${status_name}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
target = sys.argv[2]
items = payload.get("items") or []
print(sum(1 for item in items if item.get("status") == target))
PY
}

"${agent_bin}" down core >/tmp/agent-k8-down-pre.out 2>&1 || true
"${REPO_ROOT}/deployments/core/init_runtime.sh"

agentic_root="${AGENTIC_ROOT}"
webhook_host_port="${OPENCLAW_WEBHOOK_HOST_PORT:-18111}"
install -d -m 0700 "${agentic_root}/secrets/runtime"

cat >"${agentic_root}/openclaw/config/dm_allowlist.txt" <<'ALLOW'
discord:user:allowed
ALLOW
chmod 0644 "${agentic_root}/openclaw/config/dm_allowlist.txt"

cat >"${agentic_root}/openclaw/config/tool_allowlist.txt" <<'ALLOW'
diagnostics.ping
ALLOW
chmod 0644 "${agentic_root}/openclaw/config/tool_allowlist.txt"

cat >"${agentic_root}/openclaw/config/relay_targets.json" <<'JSON'
{
  "providers": {
    "telegram": {
      "target": "discord:user:allowed"
    }
  }
}
JSON
chmod 0644 "${agentic_root}/openclaw/config/relay_targets.json"

claw_token="k8-test-token-$(date +%s)"
printf '%s\n' "${claw_token}" >"${agentic_root}/secrets/runtime/openclaw.token"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.token"

webhook_secret="k8-webhook-secret-$(date +%s)"
printf '%s\n' "${webhook_secret}" >"${agentic_root}/secrets/runtime/openclaw.webhook_secret"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.webhook_secret"

telegram_secret="k8-telegram-secret-$(date +%s)"
printf '%s\n' "${telegram_secret}" >"${agentic_root}/secrets/runtime/openclaw.relay.telegram.secret"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.relay.telegram.secret"

if [[ "${EUID}" -eq 0 ]]; then
  chown "${AGENT_RUNTIME_UID:-1000}:${AGENT_RUNTIME_GID:-1000}" \
    "${agentic_root}/secrets/runtime/openclaw.token" \
    "${agentic_root}/secrets/runtime/openclaw.webhook_secret" \
    "${agentic_root}/secrets/runtime/openclaw.relay.telegram.secret"
fi

"${agent_bin}" up core >/tmp/agent-k8-up.out \
  || fail "agent up core (openclaw approvals) failed"

openclaw_cid="$(require_service_container openclaw)" || exit 1
sandbox_cid="$(require_service_container openclaw-sandbox)" || exit 1
relay_cid="$(require_service_container openclaw-relay)" || exit 1

wait_for_container_ready "${openclaw_cid}" 90 || fail "openclaw did not become ready"
wait_for_container_ready "${sandbox_cid}" 90 || fail "openclaw-sandbox did not become ready"
wait_for_container_ready "${relay_cid}" 90 || fail "openclaw-relay did not become ready"

assert_container_security "${openclaw_cid}" || fail "openclaw container security baseline failed"
assert_container_security "${sandbox_cid}" || fail "openclaw-sandbox container security baseline failed"
assert_proxy_enforced "${openclaw_cid}" || fail "openclaw proxy env baseline failed"
assert_proxy_enforced "${sandbox_cid}" || fail "openclaw-sandbox proxy env baseline failed"
assert_no_docker_sock_mount "${openclaw_cid}" || fail "openclaw must not mount docker.sock"
assert_no_docker_sock_mount "${sandbox_cid}" || fail "openclaw-sandbox must not mount docker.sock"

openclaw_ready=0
for _ in $(seq 1 30); do
  if curl -sS -o /tmp/agent-k8-health.out -w '%{http_code}' "http://127.0.0.1:${webhook_host_port}/healthz" | grep -q '^200$'; then
    openclaw_ready=1
    break
  fi
  sleep 1
done
[[ "${openclaw_ready}" -eq 1 ]] || fail "openclaw loopback endpoint is not reachable on 127.0.0.1:${webhook_host_port}"

dm_pending_status="$(curl_json_status /tmp/agent-k8-dm-pending.json \
  -X POST \
  -H "Authorization: Bearer ${claw_token}" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"alpha","target":"discord:user:needs-approval","message":"hello"}' \
  "http://127.0.0.1:${webhook_host_port}/v1/dm")"
[[ "${dm_pending_status}" == "403" ]] || fail "unknown DM target must require approval (status=${dm_pending_status})"
dm_pending_payload="$(cat /tmp/agent-k8-dm-pending.json)"
[[ "$(json_field "${dm_pending_payload}" "error")" == "approval_required" ]] \
  || fail "unknown DM target must surface approval_required"
dm_approval_id="$(json_field "${dm_pending_payload}" "approval_id")" || fail "approval_id missing for DM queue entry"

list_payload="$(approval_items_json)"
[[ "$(approval_count "${list_payload}" "pending")" =~ ^[1-9][0-9]*$ ]] \
  || fail "approval queue must show at least one pending entry after DM deny"

"${agent_bin}" openclaw approvals approve "${dm_approval_id}" --scope session --session-id alpha --ttl-sec 3 >/tmp/agent-k8-approve.out \
  || fail "session approval command failed"

dm_allowed_status="$(curl_json_status /tmp/agent-k8-dm-allowed.json \
  -X POST \
  -H "Authorization: Bearer ${claw_token}" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"alpha","target":"discord:user:needs-approval","message":"hello approved"}' \
  "http://127.0.0.1:${webhook_host_port}/v1/dm")"
[[ "${dm_allowed_status}" == "202" ]] || fail "session-approved DM target must be accepted (status=${dm_allowed_status})"

dm_other_session_status="$(curl_json_status /tmp/agent-k8-dm-other-session.json \
  -X POST \
  -H "Authorization: Bearer ${claw_token}" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"beta","target":"discord:user:needs-approval","message":"hello beta"}' \
  "http://127.0.0.1:${webhook_host_port}/v1/dm")"
[[ "${dm_other_session_status}" == "403" ]] || fail "session approval must not open another session (status=${dm_other_session_status})"
[[ "$(json_field "$(cat /tmp/agent-k8-dm-other-session.json)" "error")" == "approval_required" ]] \
  || fail "different session must still require approval"

tool_pending_status="$(curl_json_status /tmp/agent-k8-tool-pending.json \
  -X POST \
  -H "Authorization: Bearer ${claw_token}" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"gamma","model":"qwen3-coder:30b","tool":"diagnostics.echo","args":{"message":"hello approvals"}}' \
  "http://127.0.0.1:${webhook_host_port}/v1/tools/execute")"
[[ "${tool_pending_status}" == "403" ]] || fail "unknown tool must require approval (status=${tool_pending_status})"
tool_pending_payload="$(cat /tmp/agent-k8-tool-pending.json)"
tool_approval_id="$(json_field "${tool_pending_payload}" "approval_id")" || fail "approval_id missing for tool queue entry"

"${agent_bin}" openclaw approvals promote "${tool_approval_id}" >/tmp/agent-k8-promote.out \
  || fail "persistent promotion command failed"
grep -q '^diagnostics.echo$' "${agentic_root}/openclaw/config/tool_allowlist.txt" \
  || fail "tool allowlist must contain promoted diagnostics.echo"

tool_allowed_status="$(curl_json_status /tmp/agent-k8-tool-allowed.json \
  -X POST \
  -H "Authorization: Bearer ${claw_token}" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"gamma","model":"qwen3-coder:30b","tool":"diagnostics.echo","args":{"message":"hello promoted"}}' \
  "http://127.0.0.1:${webhook_host_port}/v1/tools/execute")"
[[ "${tool_allowed_status}" == "200" ]] || fail "promoted tool must execute without restart (status=${tool_allowed_status})"
grep -q '"output":"hello promoted"' /tmp/agent-k8-tool-allowed.json \
  || fail "promoted tool execution output is missing expected echo payload"

dm_deny_pending_status="$(curl_json_status /tmp/agent-k8-dm-deny-pending.json \
  -X POST \
  -H "Authorization: Bearer ${claw_token}" \
  -H 'Content-Type: application/json' \
  -d '{"target":"discord:user:deny-me","message":"hello deny"}' \
  "http://127.0.0.1:${webhook_host_port}/v1/dm")"
[[ "${dm_deny_pending_status}" == "403" ]] || fail "deny candidate must require approval first (status=${dm_deny_pending_status})"
deny_approval_id="$(json_field "$(cat /tmp/agent-k8-dm-deny-pending.json)" "approval_id")" || fail "approval_id missing for deny candidate"

"${agent_bin}" openclaw approvals deny "${deny_approval_id}" --scope global --reason operator-block >/tmp/agent-k8-deny.out \
  || fail "deny command failed"

dm_denied_status="$(curl_json_status /tmp/agent-k8-dm-denied.json \
  -X POST \
  -H "Authorization: Bearer ${claw_token}" \
  -H 'Content-Type: application/json' \
  -d '{"target":"discord:user:deny-me","message":"hello denied"}' \
  "http://127.0.0.1:${webhook_host_port}/v1/dm")"
[[ "${dm_denied_status}" == "403" ]] || fail "globally denied DM target must stay blocked (status=${dm_denied_status})"
[[ "$(json_field "$(cat /tmp/agent-k8-dm-denied.json)" "error")" == "approval_denied" ]] \
  || fail "globally denied DM target must surface approval_denied"

sleep 4
dm_expired_status="$(curl_json_status /tmp/agent-k8-dm-expired.json \
  -X POST \
  -H "Authorization: Bearer ${claw_token}" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"alpha","target":"discord:user:needs-approval","message":"hello expired"}' \
  "http://127.0.0.1:${webhook_host_port}/v1/dm")"
[[ "${dm_expired_status}" == "403" ]] || fail "expired session approval must stop allowing traffic (status=${dm_expired_status})"
[[ "$(json_field "$(cat /tmp/agent-k8-dm-expired.json)" "error")" == "approval_required" ]] \
  || fail "expired session approval must return approval_required again"

expired_payload="$("${agent_bin}" openclaw approvals list --status expired --json)"
[[ "$(approval_count "${expired_payload}" "expired")" =~ ^[1-9][0-9]*$ ]] \
  || fail "expired approval list must contain at least one entry"

"${agent_bin}" doctor >/tmp/agent-k8-doctor.out \
  || fail "agent doctor must pass with approvals queue enabled"

audit_log="${agentic_root}/openclaw/logs/audit.jsonl"
[[ -s "${audit_log}" ]] || fail "openclaw audit log is missing: ${audit_log}"
grep -q '"module":"openclaw-approvals"' "${audit_log}" || fail "audit log must include openclaw-approvals records"
grep -q '"action":"approve"' "${audit_log}" || fail "audit log must include approve actions"
grep -q '"action":"promote"' "${audit_log}" || fail "audit log must include promote actions"
grep -q '"action":"deny"' "${audit_log}" || fail "audit log must include deny actions"
grep -q '"action":"expire"' "${audit_log}" || fail "audit log must include expire actions"

ok "K8_openclaw_approvals passed"
