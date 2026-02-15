#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K1 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd curl

"${REPO_ROOT}/deployments/optional/init_runtime.sh"

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
install -d -m 0700 "${agentic_root}/secrets/runtime"
install -d -m 0750 "${agentic_root}/deployments/optional"

cat >"${agentic_root}/deployments/optional/clawdbot.request" <<'REQ'
need=Enable controlled outbound DM notifications for maintenance alerts.
success=Unauthorized DM requests are denied and allowlisted targets are accepted.
owner=ops
expires_at=2099-12-31
REQ
chmod 0640 "${agentic_root}/deployments/optional/clawdbot.request"

cat >"${agentic_root}/optional/clawdbot/config/dm_allowlist.txt" <<'ALLOW'
discord:user:test
ALLOW
chmod 0644 "${agentic_root}/optional/clawdbot/config/dm_allowlist.txt"

claw_token="k1-test-token-$(date +%s)"
printf '%s\n' "${claw_token}" >"${agentic_root}/secrets/runtime/clawdbot.token"
chmod 0600 "${agentic_root}/secrets/runtime/clawdbot.token"
if [[ "${EUID}" -eq 0 ]]; then
  chown "${AGENT_RUNTIME_UID:-1000}:${AGENT_RUNTIME_GID:-1000}" "${agentic_root}/secrets/runtime/clawdbot.token"
fi

"${agent_bin}" doctor >/tmp/agent-k1-doctor.out \
  || fail "precondition failed: doctor must be green before validating K1"

AGENTIC_OPTIONAL_MODULES=clawdbot "${agent_bin}" up optional >/tmp/agent-k1-up.out \
  || fail "agent up optional (clawdbot) failed"

claw_cid="$(require_service_container optional-clawdbot)" || exit 1
wait_for_container_ready "${claw_cid}" 90 || fail "optional-clawdbot did not become ready"
assert_container_security "${claw_cid}" || fail "optional-clawdbot container security baseline failed"
assert_proxy_enforced "${claw_cid}" || fail "optional-clawdbot proxy env baseline failed"
assert_no_docker_sock_mount "${claw_cid}" || fail "optional-clawdbot must not mount docker.sock"

# Requests are executed from toolbox inside the private docker network.
toolbox_cid="$(require_service_container toolbox)" || exit 1

no_auth_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k1-noauth.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{\"target\":\"discord:user:test\",\"message\":\"hello\"}' http://optional-clawdbot:8111/v1/dm")"
[[ "${no_auth_status}" == "401" ]] || fail "clawdbot endpoint must reject requests without token (status=${no_auth_status})"

allow_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k1-allow.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer ${claw_token}' -d '{\"target\":\"discord:user:test\",\"message\":\"hello\"}' http://optional-clawdbot:8111/v1/dm")"
[[ "${allow_status}" == "202" ]] || fail "clawdbot allowlisted request must be accepted (status=${allow_status})"

audit_log="${agentic_root}/optional/clawdbot/logs/audit.jsonl"
[[ -s "${audit_log}" ]] || fail "clawdbot audit log is missing: ${audit_log}"
grep -q '"decision":"allow"' "${audit_log}" || fail "clawdbot audit log must include an allow decision"
grep -q '"decision":"deny"' "${audit_log}" || fail "clawdbot audit log must include a deny decision"

assert_no_public_bind 8111 || fail "clawdbot service must not expose host port 8111"

ok "K1_clawdbot passed"
