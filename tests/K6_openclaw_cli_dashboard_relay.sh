#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K6 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd curl
assert_cmd python3

relay_signature() {
  local secret="$1"
  local ts="$2"
  local body="$3"
  RELAY_SECRET="${secret}" RELAY_TS="${ts}" RELAY_BODY="${body}" python3 - <<'PY'
import hashlib
import hmac
import os

secret = os.environ["RELAY_SECRET"].encode("utf-8")
timestamp = os.environ["RELAY_TS"].encode("utf-8")
body = os.environ["RELAY_BODY"].encode("utf-8")
print(hmac.new(secret, timestamp + b"." + body, hashlib.sha256).hexdigest())
PY
}

relay_queue_value() {
  local toolbox_cid="$1"
  local field="$2"
  local payload
  payload="$(docker exec "${toolbox_cid}" sh -lc 'curl -fsS http://optional-openclaw-relay:8113/v1/queue/status')" || return 1
  python3 - "${field}" "${payload}" <<'PY'
import json
import sys

field = sys.argv[1]
payload = json.loads(sys.argv[2])
value = payload.get(field)
if not isinstance(value, int):
    raise SystemExit(2)
print(value)
PY
}

wait_for_relay_queue_at_least() {
  local toolbox_cid="$1"
  local field="$2"
  local minimum="$3"
  local timeout_sec="${4:-30}"
  local elapsed=0
  local value=""
  while (( elapsed < timeout_sec )); do
    value="$(relay_queue_value "${toolbox_cid}" "${field}" || true)"
    if [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= minimum )); then
      return 0
    fi
    sleep 1
    ((elapsed += 1))
  done
  fail "relay queue '${field}' did not reach ${minimum} within ${timeout_sec}s (last=${value:-unknown})"
}

"${agent_bin}" down optional >/tmp/agent-k6-down-pre.out 2>&1 || true
"${REPO_ROOT}/deployments/optional/init_runtime.sh"

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
webhook_host_port="${OPENCLAW_WEBHOOK_HOST_PORT:-18111}"
relay_host_port="${OPENCLAW_RELAY_HOST_PORT:-18112}"

install -d -m 0700 "${agentic_root}/secrets/runtime"
install -d -m 0750 "${agentic_root}/deployments/optional"

cat >"${agentic_root}/deployments/optional/openclaw.request" <<'REQ'
need=Validate OpenClaw CLI wizard parity, dashboard access, and provider relay delivery path.
success=CLI setup flows are persistent, dashboard stays loopback-only, and relay queue handles success plus dead-letter retries.
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

cat >"${agentic_root}/optional/openclaw/config/relay_targets.json" <<'JSON'
{
  "providers": {
    "telegram": {
      "target": "discord:user:test"
    },
    "whatsapp": {
      "target": "discord:user:test"
    }
  }
}
JSON
chmod 0644 "${agentic_root}/optional/openclaw/config/relay_targets.json"

claw_token="k6-test-token-$(date +%s)"
printf '%s\n' "${claw_token}" >"${agentic_root}/secrets/runtime/openclaw.token"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.token"

webhook_secret="k6-webhook-secret-$(date +%s)"
printf '%s\n' "${webhook_secret}" >"${agentic_root}/secrets/runtime/openclaw.webhook_secret"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.webhook_secret"

telegram_secret="k6-telegram-secret-$(date +%s)"
printf '%s\n' "${telegram_secret}" >"${agentic_root}/secrets/runtime/openclaw.relay.telegram.secret"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.relay.telegram.secret"

whatsapp_secret="k6-whatsapp-secret-$(date +%s)"
printf '%s\n' "${whatsapp_secret}" >"${agentic_root}/secrets/runtime/openclaw.relay.whatsapp.secret"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.relay.whatsapp.secret"

if [[ "${EUID}" -eq 0 ]]; then
  chown "${AGENT_RUNTIME_UID:-1000}:${AGENT_RUNTIME_GID:-1000}" \
    "${agentic_root}/secrets/runtime/openclaw.token" \
    "${agentic_root}/secrets/runtime/openclaw.webhook_secret" \
    "${agentic_root}/secrets/runtime/openclaw.relay.telegram.secret" \
    "${agentic_root}/secrets/runtime/openclaw.relay.whatsapp.secret"
fi

"${agent_bin}" doctor >/tmp/agent-k6-doctor-pre.out \
  || fail "precondition failed: doctor must be green before validating K6"

AGENTIC_OPTIONAL_MODULES=openclaw \
OPENCLAW_RELAY_MAX_ATTEMPTS=2 \
OPENCLAW_RELAY_RETRY_BASE_SEC=1 \
OPENCLAW_RELAY_RETRY_MAX_SEC=1 \
OPENCLAW_RELAY_POLL_INTERVAL_SEC=0.5 \
"${agent_bin}" up optional >/tmp/agent-k6-up.out \
  || fail "agent up optional (openclaw) failed"

openclaw_cid="$(require_service_container optional-openclaw)" || exit 1
sandbox_cid="$(require_service_container optional-openclaw-sandbox)" || exit 1
relay_cid="$(require_service_container optional-openclaw-relay)" || exit 1
toolbox_cid="$(require_service_container toolbox)" || exit 1

wait_for_container_ready "${openclaw_cid}" 90 || fail "optional-openclaw did not become ready"
wait_for_container_ready "${sandbox_cid}" 90 || fail "optional-openclaw-sandbox did not become ready"
wait_for_container_ready "${relay_cid}" 90 || fail "optional-openclaw-relay did not become ready"

assert_container_security "${openclaw_cid}" || fail "optional-openclaw container security baseline failed"
assert_container_security "${sandbox_cid}" || fail "optional-openclaw-sandbox container security baseline failed"
assert_container_security "${relay_cid}" || fail "optional-openclaw-relay container security baseline failed"
assert_proxy_enforced "${openclaw_cid}" || fail "optional-openclaw proxy env baseline failed"
assert_proxy_enforced "${sandbox_cid}" || fail "optional-openclaw-sandbox proxy env baseline failed"
assert_proxy_enforced "${relay_cid}" || fail "optional-openclaw-relay proxy env baseline failed"
assert_no_docker_sock_mount "${openclaw_cid}" || fail "optional-openclaw must not mount docker.sock"
assert_no_docker_sock_mount "${sandbox_cid}" || fail "optional-openclaw-sandbox must not mount docker.sock"
assert_no_docker_sock_mount "${relay_cid}" || fail "optional-openclaw-relay must not mount docker.sock"

relay_ready=0
for _ in $(seq 1 30); do
  relay_health_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k6-relay-health.out -w '%{http_code}' http://optional-openclaw-relay:8113/healthz" || true)"
  if [[ "${relay_health_status}" == "200" ]]; then
    relay_ready=1
    break
  fi
  sleep 1
done
[[ "${relay_ready}" -eq 1 ]] || fail "optional-openclaw-relay is not reachable on internal health endpoint"

AGENT_NO_ATTACH=1 "${agent_bin}" openclaw >/tmp/agent-k6-openclaw-entrypoint.out \
  || fail "agent openclaw operator entrypoint must be available"
grep -q 'OpenClaw dashboard is available' /tmp/agent-k6-openclaw-entrypoint.out \
  || fail "agent openclaw output must mention dashboard URL"
grep -q 'provider relay ingress is available' /tmp/agent-k6-openclaw-entrypoint.out \
  || fail "agent openclaw output must mention relay ingress URL"

openclaw_version="$(docker exec "${openclaw_cid}" sh -lc 'openclaw --version' 2>/tmp/agent-k6-openclaw-version.err || true)"
echo "${openclaw_version}" | grep -q 'openclaw-stack-shim' \
  || fail "openclaw CLI shim version output is missing expected marker"

docker exec "${openclaw_cid}" sh -lc 'openclaw onboard --workspace wizard-k6 --non-interactive' >/tmp/agent-k6-openclaw-onboard.out \
  || fail "openclaw onboard must succeed in-container"
docker exec "${openclaw_cid}" sh -lc 'openclaw configure --section channels --set default_target=discord:user:test --set mode=wizard' >/tmp/agent-k6-openclaw-configure.out \
  || fail "openclaw configure must succeed in-container"
docker exec "${openclaw_cid}" sh -lc 'openclaw agents add operator-k6 --channel discord --role ops' >/tmp/agent-k6-openclaw-agents-add.out \
  || fail "openclaw agents add must succeed in-container"

set +e
docker exec "${openclaw_cid}" sh -lc 'openclaw configure --section channels --set invalid' >/tmp/agent-k6-openclaw-configure-invalid.out 2>&1
configure_invalid_rc=$?
set -e
[[ "${configure_invalid_rc}" -eq 2 ]] \
  || fail "openclaw configure must fail with actionable error on invalid --set value"
grep -q 'invalid --set value' /tmp/agent-k6-openclaw-configure-invalid.out \
  || fail "openclaw configure invalid path must return explicit invalid --set guidance"

docker exec "${openclaw_cid}" sh -lc 'openclaw agents list' >/tmp/agent-k6-openclaw-agents-list.out \
  || fail "openclaw agents list must succeed"
grep -q '"name": "operator-k6"' /tmp/agent-k6-openclaw-agents-list.out \
  || fail "openclaw agents list must include operator-k6"

python3 - "${agentic_root}" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
config = json.loads((root / "optional/openclaw/state/cli/config.json").read_text(encoding="utf-8"))
agents = json.loads((root / "optional/openclaw/state/cli/agents.json").read_text(encoding="utf-8"))
onboard = json.loads((root / "optional/openclaw/state/cli/onboard.json").read_text(encoding="utf-8"))

channels = config.get("sections", {}).get("channels", {})
if channels.get("default_target") != "discord:user:test":
    raise SystemExit("openclaw configure did not persist channels.default_target")
if channels.get("mode") != "wizard":
    raise SystemExit("openclaw configure did not persist channels.mode")
if onboard.get("workspace", "").endswith("/wizard-k6") is False:
    raise SystemExit("openclaw onboard did not persist expected workspace path")

items = agents.get("agents", [])
if not any(isinstance(item, dict) and item.get("name") == "operator-k6" for item in items):
    raise SystemExit("openclaw agents add did not persist operator-k6 entry")
PY

[[ -d "${agentic_root}/optional/openclaw/workspaces/wizard-k6" ]] \
  || fail "openclaw onboard workspace must persist under optional/openclaw/workspaces"

dashboard_status="$(curl -sS -o /tmp/agent-k6-dashboard.html -w '%{http_code}' "http://127.0.0.1:${webhook_host_port}/dashboard")"
[[ "${dashboard_status}" == "200" ]] || fail "openclaw dashboard must be reachable on loopback (status=${dashboard_status})"
grep -q 'OpenClaw Operator Dashboard' /tmp/agent-k6-dashboard.html \
  || fail "dashboard HTML payload must include OpenClaw Operator Dashboard marker"

dashboard_api_status="$(curl -sS -o /tmp/agent-k6-dashboard-status.json -w '%{http_code}' "http://127.0.0.1:${webhook_host_port}/v1/dashboard/status")"
[[ "${dashboard_api_status}" == "200" ]] || fail "dashboard status endpoint must be reachable (status=${dashboard_api_status})"
python3 - <<'PY' /tmp/agent-k6-dashboard-status.json
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
runtime = payload.get("runtime")
relay = payload.get("relay")
if not isinstance(runtime, dict) or runtime.get("mode") != "openclaw":
    raise SystemExit("dashboard runtime payload is invalid")
if not isinstance(relay, dict):
    raise SystemExit("dashboard relay payload is invalid")
for field in ("pending", "done", "dead"):
    if field not in relay:
        raise SystemExit(f"dashboard relay payload missing field: {field}")
PY

relay_body='{"message":"relay hello from k6","target":"discord:user:test"}'
relay_ts="$(date +%s)"
relay_sig="$(relay_signature "${telegram_secret}" "${relay_ts}" "${relay_body}")"
relay_ingest_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k6-relay-ingest.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Relay-Timestamp: ${relay_ts}' -H 'X-Relay-Signature: sha256=${relay_sig}' -d '${relay_body}' http://optional-openclaw-relay:8113/v1/providers/telegram/webhook")"
[[ "${relay_ingest_status}" == "202" ]] || fail "relay ingest happy-path must return 202 (status=${relay_ingest_status})"
docker exec "${toolbox_cid}" sh -lc 'cat /tmp/k6-relay-ingest.out' >/tmp/agent-k6-relay-ingest.out
python3 - <<'PY' /tmp/agent-k6-relay-ingest.out
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") not in ("queued", "duplicate"):
    raise SystemExit("relay happy-path must return queued/duplicate status")
if not payload.get("event_id"):
    raise SystemExit("relay happy-path must return event_id")
PY

wait_for_relay_queue_at_least "${toolbox_cid}" "done" 1 30

relay_bad_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k6-relay-invalid-signature.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Relay-Timestamp: ${relay_ts}' -H 'X-Relay-Signature: sha256=deadbeef' -d '${relay_body}' http://optional-openclaw-relay:8113/v1/providers/telegram/webhook")"
[[ "${relay_bad_status}" == "403" ]] || fail "relay ingest must reject invalid provider signature (status=${relay_bad_status})"

dup_body='{"message":"relay duplicate check","target":"discord:user:test"}'
dup_event_id="k6-duplicate-event"
dup_ts_1="$(date +%s)"
dup_sig_1="$(relay_signature "${telegram_secret}" "${dup_ts_1}" "${dup_body}")"
dup_first_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k6-relay-dup-first.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Provider-Event-ID: ${dup_event_id}' -H 'X-Relay-Timestamp: ${dup_ts_1}' -H 'X-Relay-Signature: sha256=${dup_sig_1}' -d '${dup_body}' http://optional-openclaw-relay:8113/v1/providers/telegram/webhook")"
[[ "${dup_first_status}" == "202" ]] || fail "relay duplicate first ingest must return 202 (status=${dup_first_status})"

dup_ts_2="$(date +%s)"
dup_sig_2="$(relay_signature "${telegram_secret}" "${dup_ts_2}" "${dup_body}")"
dup_second_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k6-relay-dup-second.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Provider-Event-ID: ${dup_event_id}' -H 'X-Relay-Timestamp: ${dup_ts_2}' -H 'X-Relay-Signature: sha256=${dup_sig_2}' -d '${dup_body}' http://optional-openclaw-relay:8113/v1/providers/telegram/webhook")"
[[ "${dup_second_status}" == "202" ]] || fail "relay duplicate second ingest must return 202 (status=${dup_second_status})"
docker exec "${toolbox_cid}" sh -lc 'cat /tmp/k6-relay-dup-second.out' >/tmp/agent-k6-relay-dup-second.out
grep -q '"status":"duplicate"' /tmp/agent-k6-relay-dup-second.out \
  || fail "relay duplicate second ingest must return duplicate status"

docker stop "${openclaw_cid}" >/tmp/agent-k6-stop-openclaw.out 2>&1 \
  || fail "failed to stop optional-openclaw for relay dead-letter scenario"

dead_body='{"message":"relay dead-letter scenario","target":"discord:user:test"}'
dead_event_id="k6-dead-letter-event"
dead_ts="$(date +%s)"
dead_sig="$(relay_signature "${telegram_secret}" "${dead_ts}" "${dead_body}")"
dead_ingest_status="$(docker exec "${toolbox_cid}" sh -lc "curl -sS -o /tmp/k6-relay-dead-ingest.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Provider-Event-ID: ${dead_event_id}' -H 'X-Relay-Timestamp: ${dead_ts}' -H 'X-Relay-Signature: sha256=${dead_sig}' -d '${dead_body}' http://optional-openclaw-relay:8113/v1/providers/telegram/webhook")"
[[ "${dead_ingest_status}" == "202" ]] || fail "relay dead-letter ingest must still return 202 (status=${dead_ingest_status})"

wait_for_relay_queue_at_least "${toolbox_cid}" "dead" 1 45

relay_audit_log="${agentic_root}/optional/openclaw/relay/logs/relay-audit.jsonl"
[[ -s "${relay_audit_log}" ]] || fail "relay audit log is missing: ${relay_audit_log}"
grep -q '"action":"forward"' "${relay_audit_log}" || fail "relay audit log must include forward action entries"
grep -q '"action":"retry_scheduled"' "${relay_audit_log}" || fail "relay audit log must include retry_scheduled entries"
grep -q '"reason":"max_attempts_exceeded"' "${relay_audit_log}" || fail "relay audit log must include max_attempts_exceeded dead-letter entry"

assert_no_public_bind 8111 "${webhook_host_port}" "${relay_host_port}" \
  || fail "openclaw dashboard and relay ports must remain loopback-only"

ok "K6_openclaw_cli_dashboard_relay passed"
