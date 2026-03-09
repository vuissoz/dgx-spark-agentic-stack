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
assert_cmd python3

"${agent_bin}" down optional >/tmp/agent-k1-down-pre.out 2>&1 || true

"${REPO_ROOT}/deployments/optional/init_runtime.sh"

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
webhook_host_port="${OPENCLAW_WEBHOOK_HOST_PORT:-18111}"
fixture_src="${SCRIPT_DIR}/fixtures/ollama-drift"
install -d -m 0700 "${agentic_root}/secrets/runtime"
install -d -m 0750 "${agentic_root}/deployments/optional"
[[ -d "${fixture_src}" ]] || fail "fixture directory missing: ${fixture_src}"

openclaw_profile_file="${agentic_root}/optional/openclaw/config/integration-profile.current.json"
[[ -s "${openclaw_profile_file}" ]] || fail "openclaw integration profile file is missing after init_runtime: ${openclaw_profile_file}"
python3 - "${openclaw_profile_file}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
runtime = payload.get("runtime") or {}
endpoints = runtime.get("endpoints") or {}

assert payload.get("profile_id"), "profile_id is required"
assert payload.get("profile_version"), "profile_version is required"
for key in ("dm", "webhook_dm", "tool_execute", "sandbox_execute", "profile"):
    assert isinstance(endpoints.get(key), list) and endpoints.get(key), f"runtime.endpoints.{key} must be non-empty"
assert "/v1/dm" in endpoints.get("dm", []), "runtime.endpoints.dm must include /v1/dm"
assert "/v1/webhooks/dm" in endpoints.get("webhook_dm", []), "runtime.endpoints.webhook_dm must include /v1/webhooks/dm"
assert "/v1/tools/execute" in endpoints.get("tool_execute", []), "runtime.endpoints.tool_execute must include /v1/tools/execute"
assert "/v1/profile" in endpoints.get("profile", []), "runtime.endpoints.profile must include /v1/profile"
PY

cat >"${agentic_root}/deployments/optional/openclaw.request" <<'REQ'
need=Enable controlled outbound DM notifications for maintenance alerts.
success=Unauthorized DM and webhook requests are denied while allowlisted targets/tools are accepted.
owner=ops
expires_at=2099-12-31
REQ
chmod 0640 "${agentic_root}/deployments/optional/openclaw.request"

cat >"${agentic_root}/optional/openclaw/config/dm_allowlist.txt" <<'ALLOW'
discord:user:test
ALLOW
chmod 0644 "${agentic_root}/optional/openclaw/config/dm_allowlist.txt"

cat >"${agentic_root}/optional/openclaw/config/tool_allowlist.txt" <<'ALLOW'
diagnostics.ping
ALLOW
chmod 0644 "${agentic_root}/optional/openclaw/config/tool_allowlist.txt"

claw_token="k1-test-token-$(date +%s)"
printf '%s\n' "${claw_token}" >"${agentic_root}/secrets/runtime/openclaw.token"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.token"

webhook_secret="k1-webhook-secret-$(date +%s)"
printf '%s\n' "${webhook_secret}" >"${agentic_root}/secrets/runtime/openclaw.webhook_secret"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.webhook_secret"

if [[ "${EUID}" -eq 0 ]]; then
  chown "${AGENT_RUNTIME_UID:-1000}:${AGENT_RUNTIME_GID:-1000}" \
    "${agentic_root}/secrets/runtime/openclaw.token" \
    "${agentic_root}/secrets/runtime/openclaw.webhook_secret"
fi

"${agent_bin}" doctor >/tmp/agent-k1-doctor.out \
  || fail "precondition failed: doctor must be green before validating K1"

AGENTIC_OPTIONAL_MODULES=openclaw "${agent_bin}" up optional >/tmp/agent-k1-up.out \
  || fail "agent up optional (openclaw) failed"

claw_cid="$(require_service_container optional-openclaw)" || exit 1
wait_for_container_ready "${claw_cid}" 90 || fail "optional-openclaw did not become ready"
assert_container_security "${claw_cid}" || fail "optional-openclaw container security baseline failed"
assert_proxy_enforced "${claw_cid}" || fail "optional-openclaw proxy env baseline failed"
assert_no_docker_sock_mount "${claw_cid}" || fail "optional-openclaw must not mount docker.sock"

AGENT_NO_ATTACH=1 "${agent_bin}" openclaw >/tmp/agent-k1-openclaw-entrypoint.out \
  || fail "agent openclaw operator entrypoint must be available"
grep -q 'optional OpenClaw service shell' /tmp/agent-k1-openclaw-entrypoint.out \
  || fail "agent openclaw output must mention optional OpenClaw service shell"
grep -q "127.0.0.1:${webhook_host_port}" /tmp/agent-k1-openclaw-entrypoint.out \
  || fail "agent openclaw output must mention loopback OpenClaw endpoint"

set +e
timeout 5 "${agent_bin}" logs openclaw >/tmp/agent-k1-openclaw-logs.out 2>&1
logs_openclaw_rc=$?
set -e
if [[ "${logs_openclaw_rc}" -ne 0 && "${logs_openclaw_rc}" -ne 124 ]]; then
  cat /tmp/agent-k1-openclaw-logs.out >&2
  fail "agent logs openclaw must resolve to optional-openclaw service"
fi
if grep -q "No such container: openclaw" /tmp/agent-k1-openclaw-logs.out; then
  cat /tmp/agent-k1-openclaw-logs.out >&2
  fail "agent logs openclaw must not target a non-existent 'openclaw' container"
fi

sandbox_cid="$(require_service_container optional-openclaw-sandbox)" || exit 1
wait_for_container_ready "${sandbox_cid}" 90 || fail "optional-openclaw-sandbox did not become ready"
assert_container_security "${sandbox_cid}" || fail "optional-openclaw-sandbox container security baseline failed"
assert_proxy_enforced "${sandbox_cid}" || fail "optional-openclaw-sandbox proxy env baseline failed"
assert_no_docker_sock_mount "${sandbox_cid}" || fail "optional-openclaw-sandbox must not mount docker.sock"

# Requests are executed from toolbox inside the private docker network.
toolbox_cid="$(require_service_container toolbox)" || exit 1

sandbox_health_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k1-sandbox-health.out -w '%{http_code}' http://optional-openclaw:8111/v1/sandbox/health")"
[[ "${sandbox_health_status}" == "200" ]] || fail "openclaw must report sandbox reachable (status=${sandbox_health_status})"

profile_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k1-profile.out -w '%{http_code}' http://optional-openclaw:8111/v1/profile")"
[[ "${profile_status}" == "200" ]] || fail "openclaw profile endpoint must be reachable (status=${profile_status})"
docker exec "${toolbox_cid}" sh -lc "grep -q '\"profile_id\":\"openclaw.launch-inspired\"' /tmp/k1-profile.out" \
  || fail "openclaw profile endpoint must expose profile_id"
docker exec "${toolbox_cid}" sh -lc "grep -q '\"capabilities\":' /tmp/k1-profile.out" \
  || fail "openclaw profile endpoint must expose capabilities"

no_auth_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k1-noauth.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{\"target\":\"discord:user:test\",\"message\":\"hello\"}' http://optional-openclaw:8111/v1/dm")"
[[ "${no_auth_status}" == "401" ]] || fail "openclaw endpoint must reject requests without token (status=${no_auth_status})"

allow_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k1-allow.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer ${claw_token}' -d '{\"target\":\"discord:user:test\",\"message\":\"hello\"}' http://optional-openclaw:8111/v1/dm")"
[[ "${allow_status}" == "202" ]] || fail "openclaw allowlisted request must be accepted (status=${allow_status})"

allow_alias_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k1-allow-alias.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer ${claw_token}' -d '{\"target\":\"discord:user:test\",\"message\":\"hello alias\"}' http://optional-openclaw:8111/v1/dm/send")"
[[ "${allow_alias_status}" == "202" ]] || fail "openclaw DM alias endpoint must be accepted (status=${allow_alias_status})"

tool_deny_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k1-tool-deny.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer ${claw_token}' -d '{\"tool\":\"filesystem.read\"}' http://optional-openclaw:8111/v1/tools/execute")"
[[ "${tool_deny_status}" == "403" ]] || fail "non-allowlisted openclaw tool must be denied (status=${tool_deny_status})"

tool_allow_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k1-tool-allow.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer ${claw_token}' -H 'X-Request-ID: k1-allow-tool' -d '{\"tool\":\"diagnostics.ping\",\"args\":{\"message\":\"hello\"}}' http://optional-openclaw:8111/v1/tools/execute")"
[[ "${tool_allow_status}" == "200" ]] || fail "allowlisted openclaw tool must execute via sandbox (status=${tool_allow_status})"
docker exec "${toolbox_cid}" sh -lc "grep -q '\"output\":\"pong\"' /tmp/k1-tool-allow.out" \
  || fail "sandbox tool execution output is missing expected pong payload"

webhook_body='{"target":"discord:user:test","message":"webhook hello"}'
webhook_ts="$(date +%s)"
webhook_sig="$(WEBHOOK_SECRET="${webhook_secret}" WEBHOOK_TS="${webhook_ts}" WEBHOOK_BODY="${webhook_body}" python3 - <<'PY'
import hashlib
import hmac
import os

secret = os.environ["WEBHOOK_SECRET"].encode("utf-8")
timestamp = os.environ["WEBHOOK_TS"].encode("utf-8")
body = os.environ["WEBHOOK_BODY"].encode("utf-8")
print(hmac.new(secret, timestamp + b'.' + body, hashlib.sha256).hexdigest())
PY
)"

# Wait briefly for loopback webhook ingress publication on the host.
webhook_ready=0
for _ in $(seq 1 20); do
  if curl -sS -o /tmp/k1-webhook-health.out -w '%{http_code}' "http://127.0.0.1:${webhook_host_port}/healthz" | grep -q '^200$'; then
    webhook_ready=1
    break
  fi
  sleep 1
done
[[ "${webhook_ready}" -eq 1 ]] || fail "openclaw webhook ingress is not reachable on 127.0.0.1:${webhook_host_port}"

webhook_allow_status="$(curl -sS -o /tmp/k1-webhook-allow.out -w '%{http_code}' -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${claw_token}" \
  -H "X-Webhook-Timestamp: ${webhook_ts}" \
  -H "X-Webhook-Signature: sha256=${webhook_sig}" \
  -d "${webhook_body}" \
  "http://127.0.0.1:${webhook_host_port}/v1/webhooks/dm")"
[[ "${webhook_allow_status}" == "202" ]] || fail "signed webhook must be accepted on loopback ingress (status=${webhook_allow_status})"

webhook_deny_status="$(curl -sS -o /tmp/k1-webhook-deny.out -w '%{http_code}' -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${claw_token}" \
  -H "X-Webhook-Timestamp: ${webhook_ts}" \
  -H "X-Webhook-Signature: sha256=deadbeef" \
  -d "${webhook_body}" \
  "http://127.0.0.1:${webhook_host_port}/v1/webhooks/dm")"
[[ "${webhook_deny_status}" == "403" ]] || fail "invalid webhook signature must be rejected (status=${webhook_deny_status})"

audit_log="${agentic_root}/optional/openclaw/logs/audit.jsonl"
[[ -s "${audit_log}" ]] || fail "openclaw audit log is missing: ${audit_log}"
grep -q '"decision":"allow"' "${audit_log}" || fail "openclaw audit log must include an allow decision"
grep -q '"decision":"deny"' "${audit_log}" || fail "openclaw audit log must include a deny decision"
grep -q '"module":"openclaw-sandbox"' "${audit_log}" || fail "audit log must include openclaw-sandbox records"
grep -q '"action":"webhook_dm"' "${audit_log}" || fail "audit log must include webhook actions"
grep -q '"request_id":"k1-allow-tool"' "${audit_log}" || fail "audit log must include request_id correlation"

drift_fixture_tmp="$(mktemp -d)"
drift_state_dir="${agentic_root}/deployments/ollama-drift-k1-openclaw"
cp -R "${fixture_src}/." "${drift_fixture_tmp}/"

set +e
"${agent_bin}" ollama-drift watch \
  --no-beads \
  --sources openclaw \
  --sources-dir "${drift_fixture_tmp}" \
  --state-dir "${drift_state_dir}" >/tmp/agent-k1-drift-ok.out 2>&1
drift_ok_rc=$?
set -e
[[ "${drift_ok_rc}" -eq 0 ]] || {
  cat /tmp/agent-k1-drift-ok.out >&2
  fail "openclaw drift watch must pass with baseline fixtures"
}

sed -i '/openclaw gateway stop/d' "${drift_fixture_tmp}/openclaw.mdx"

set +e
"${agent_bin}" ollama-drift watch \
  --no-beads \
  --sources openclaw \
  --sources-dir "${drift_fixture_tmp}" \
  --state-dir "${drift_state_dir}" >/tmp/agent-k1-drift-fail.out 2>&1
drift_fail_rc=$?
set -e
rm -rf "${drift_fixture_tmp}" >/dev/null 2>&1 || true
[[ "${drift_fail_rc}" -eq 2 ]] || {
  cat /tmp/agent-k1-drift-fail.out >&2
  fail "openclaw drift watch must fail (exit=2) when invariant drifts"
}
grep -q 'openclaw:missing:openclaw gateway stop' "${drift_state_dir}/latest-report.txt" \
  || fail "drift report must include missing openclaw gateway stop invariant"

if [[ "${AGENTIC_PROFILE:-strict-prod}" == "rootless-dev" ]]; then
  warn "skip strict direct-egress assertion in rootless-dev profile"
else
  set +e
  docker exec "${claw_cid}" sh -lc "env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY python3 -c 'import urllib.request; urllib.request.urlopen(\"https://example.com\", timeout=6)'" >/tmp/k1-openclaw-direct-egress.out 2>&1
  openclaw_direct_rc=$?
  docker exec "${sandbox_cid}" sh -lc "env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY python3 -c 'import urllib.request; urllib.request.urlopen(\"https://example.com\", timeout=6)'" >/tmp/k1-sandbox-direct-egress.out 2>&1
  sandbox_direct_rc=$?
  set -e
  [[ "${openclaw_direct_rc}" -ne 0 ]] || fail "openclaw direct egress without proxy must be blocked"
  [[ "${sandbox_direct_rc}" -ne 0 ]] || fail "openclaw sandbox direct egress without proxy must be blocked"
fi

assert_no_public_bind 8111 "${webhook_host_port}" || fail "openclaw ports must not expose non-loopback listeners"

ok "K1_openclaw passed"
