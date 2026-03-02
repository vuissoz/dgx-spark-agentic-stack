#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K2 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd curl

"${agent_bin}" down optional >/tmp/agent-k2-down-pre.out 2>&1 || true

"${REPO_ROOT}/deployments/optional/init_runtime.sh"

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
agentic_profile="${AGENTIC_PROFILE:-strict-prod}"
if [[ -n "${AGENTIC_AGENT_WORKSPACES_ROOT:-}" ]]; then
  agent_workspaces_root="${AGENTIC_AGENT_WORKSPACES_ROOT}"
elif [[ "${agentic_profile}" == "rootless-dev" ]]; then
  agent_workspaces_root="${agentic_root}/agent-workspaces"
else
  agent_workspaces_root="${agentic_root}"
fi
install -d -m 0700 "${agentic_root}/secrets/runtime"
install -d -m 0750 "${agentic_root}/deployments/optional"

cat >"${agentic_root}/deployments/optional/mcp.request" <<'REQ'
need=Expose a tightly scoped MCP tool catalog for local automation workflows.
success=Non-allowlisted tools are denied and allowlisted tools are accepted.
owner=ops
expires_at=2099-12-31
REQ
chmod 0640 "${agentic_root}/deployments/optional/mcp.request"

cat >"${agentic_root}/optional/mcp/config/tool_allowlist.txt" <<'ALLOW'
filesystem.read
ALLOW
chmod 0644 "${agentic_root}/optional/mcp/config/tool_allowlist.txt"

mcp_token="k2-test-token-$(date +%s)"
printf '%s\n' "${mcp_token}" >"${agentic_root}/secrets/runtime/mcp.token"
chmod 0600 "${agentic_root}/secrets/runtime/mcp.token"
if [[ "${EUID}" -eq 0 ]]; then
  chown "${AGENT_RUNTIME_UID:-1000}:${AGENT_RUNTIME_GID:-1000}" "${agentic_root}/secrets/runtime/mcp.token"
fi

"${agent_bin}" doctor >/tmp/agent-k2-doctor.out \
  || fail "precondition failed: doctor must be green before validating K2"

AGENTIC_OPTIONAL_MODULES=mcp "${agent_bin}" up optional >/tmp/agent-k2-up.out \
  || fail "agent up optional (mcp) failed"

mcp_cid="$(require_service_container optional-mcp-catalog)" || exit 1
wait_for_container_ready "${mcp_cid}" 90 || fail "optional-mcp-catalog did not become ready"
assert_container_security "${mcp_cid}" || fail "optional-mcp-catalog container security baseline failed"
assert_proxy_enforced "${mcp_cid}" || fail "optional-mcp-catalog proxy env baseline failed"
assert_no_docker_sock_mount "${mcp_cid}" || fail "optional-mcp-catalog must not mount docker.sock"

# Requests are executed from toolbox inside the private docker network.
toolbox_cid="$(require_service_container toolbox)" || exit 1

unauth_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k2-unauth.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{\"tool\":\"filesystem.read\"}' http://optional-mcp-catalog:8122/v1/tools/execute")"
[[ "${unauth_status}" == "401" ]] || fail "mcp endpoint must reject requests without token (status=${unauth_status})"

deny_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k2-deny.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer ${mcp_token}' -d '{\"tool\":\"filesystem.write\"}' http://optional-mcp-catalog:8122/v1/tools/execute")"
[[ "${deny_status}" == "403" ]] || fail "non-allowlisted tool must be denied (status=${deny_status})"

allow_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k2-allow.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer ${mcp_token}' -d '{\"tool\":\"filesystem.read\"}' http://optional-mcp-catalog:8122/v1/tools/execute")"
[[ "${allow_status}" == "200" ]] || fail "allowlisted tool must be accepted (status=${allow_status})"

audit_log="${agentic_root}/optional/mcp/logs/audit.jsonl"
[[ -s "${audit_log}" ]] || fail "mcp audit log is missing: ${audit_log}"
grep -q '"decision":"allow"' "${audit_log}" || fail "mcp audit log must include an allow decision"
grep -q '"decision":"deny"' "${audit_log}" || fail "mcp audit log must include a deny decision"

# Secret value must stay outside user workspaces.
for workspace in \
  "${agent_workspaces_root}/claude/workspaces" \
  "${agent_workspaces_root}/codex/workspaces" \
  "${agent_workspaces_root}/opencode/workspaces"; do
  [[ -d "${workspace}" ]] || continue
  if grep -Rqs --binary-files=without-match -- "${mcp_token}" "${workspace}"; then
    fail "mcp token leaked into workspace: ${workspace}"
  fi
done

assert_no_public_bind 8122 || fail "mcp service must not expose host port 8122"

ok "K2_mcp passed"
