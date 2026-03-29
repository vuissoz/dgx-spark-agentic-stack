#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K9 skipped because AGENTIC_SKIP_K_TESTS=1"
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

"${agent_bin}" down core >/tmp/agent-k9-down-pre.out 2>&1 || true
"${REPO_ROOT}/deployments/core/init_runtime.sh"

agentic_root="${AGENTIC_ROOT}"
install -d -m 0700 "${agentic_root}/secrets/runtime"

cat >"${agentic_root}/openclaw/config/dm_allowlist.txt" <<'ALLOW'
discord:user:test
ALLOW
chmod 0644 "${agentic_root}/openclaw/config/dm_allowlist.txt"

cat >"${agentic_root}/openclaw/config/tool_allowlist.txt" <<'ALLOW'
diagnostics.echo
ALLOW
chmod 0644 "${agentic_root}/openclaw/config/tool_allowlist.txt"

claw_token="k9-test-token-$(date +%s)"
printf '%s\n' "${claw_token}" >"${agentic_root}/secrets/runtime/openclaw.token"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.token"

webhook_secret="k9-webhook-secret-$(date +%s)"
printf '%s\n' "${webhook_secret}" >"${agentic_root}/secrets/runtime/openclaw.webhook_secret"
chmod 0600 "${agentic_root}/secrets/runtime/openclaw.webhook_secret"

if [[ "${EUID}" -eq 0 ]]; then
  chown "${AGENT_RUNTIME_UID:-1000}:${AGENT_RUNTIME_GID:-1000}" \
    "${agentic_root}/secrets/runtime/openclaw.token" \
    "${agentic_root}/secrets/runtime/openclaw.webhook_secret"
fi

"${agent_bin}" up core >/tmp/agent-k9-up.out \
  || fail "agent up core (openclaw operator planes) failed"

openclaw_cid="$(require_service_container openclaw)" || exit 1
sandbox_cid="$(require_service_container openclaw-sandbox)" || exit 1
toolbox_cid="$(require_service_container toolbox)" || exit 1

wait_for_container_ready "${openclaw_cid}" 90 || fail "openclaw did not become ready"
wait_for_container_ready "${sandbox_cid}" 90 || fail "openclaw-sandbox did not become ready"

openclaw_env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${openclaw_cid}" 2>/dev/null || true)"
printf '%s\n' "${openclaw_env_dump}" | grep -q "^AGENTIC_CONTEXT_BUDGET_TOKENS=${AGENTIC_CONTEXT_BUDGET_TOKENS}$" \
  || fail "openclaw must expose AGENTIC_CONTEXT_BUDGET_TOKENS"
printf '%s\n' "${openclaw_env_dump}" | grep -q "^AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS=${AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS}$" \
  || fail "openclaw must expose AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS"
printf '%s\n' "${openclaw_env_dump}" | grep -q "^AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS=${AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS}$" \
  || fail "openclaw must expose AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS"

python3 "${REPO_ROOT}/deployments/optional/openclaw_module_manifest.py" validate \
  --manifest-file "${agentic_root}/openclaw/config/module/openclaw.module-manifest.v1.json" \
  >/tmp/agent-k9-manifest.out 2>&1 \
  || fail "openclaw module manifest must validate"

status_before="$("${agent_bin}" openclaw status --json)"
[[ "$(json_field "${status_before}" "manifest.manifest_id")" == "openclaw.module.blueprint.v1" ]] \
  || fail "agent openclaw status must expose module manifest id"

"${agent_bin}" openclaw model set "qwen3-coder:14b" >/tmp/agent-k9-model-set.out \
  || fail "agent openclaw model set must succeed"
grep -q '^default_model=qwen3-coder:14b$' /tmp/agent-k9-model-set.out \
  || fail "agent openclaw model set must report updated default model"

runtime_default_model="$(python3 - "${agentic_root}/openclaw/config/operator-runtime.v1.json" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload.get("default_model", ""))
PY
)"
[[ "${runtime_default_model}" == "qwen3-coder:14b" ]] \
  || fail "operator runtime file must persist updated default model"

tool_payload="$(docker exec "${toolbox_cid}" sh -lc "curl -fsS -X POST \
  -H 'Authorization: Bearer ${claw_token}' \
  -H 'Content-Type: application/json' \
  -d '{\"session_id\":\"operator-plane\",\"tool\":\"diagnostics.echo\",\"args\":{\"message\":\"hello operator plane\"}}' \
  http://openclaw:8111/v1/tools/execute")" \
  || fail "openclaw tool execution through main API failed"

sandbox_id="$(json_field "${tool_payload}" "sandbox_id")" || fail "sandbox_id missing in tool execution payload"
[[ "$(json_field "${tool_payload}" "model")" == "qwen3-coder:14b" ]] \
  || fail "tool execution without explicit model must use operator default model"

internal_list_payload="$(docker exec "${toolbox_cid}" sh -lc "curl -fsS -H 'Authorization: Bearer ${claw_token}' http://openclaw-sandbox:8112/v1/internal/sandboxes")" \
  || fail "internal sandbox lifecycle list endpoint failed"
[[ "$(json_field "${internal_list_payload}" "active")" == "1" ]] \
  || fail "internal sandbox lifecycle list must report one active sandbox"

internal_get_payload="$(docker exec "${toolbox_cid}" sh -lc "curl -fsS -H 'Authorization: Bearer ${claw_token}' http://openclaw-sandbox:8112/v1/internal/sandboxes/${sandbox_id}")" \
  || fail "internal sandbox lifecycle get endpoint failed"
[[ "$(json_field "${internal_get_payload}" "sandbox_id")" == "${sandbox_id}" ]] \
  || fail "internal sandbox lifecycle get must return the requested sandbox"

status_after="$("${agent_bin}" openclaw status --json)"
[[ "$(json_field "${status_after}" "default_model")" == "qwen3-coder:14b" ]] \
  || fail "agent openclaw status must expose the operator runtime default model"
[[ "$(json_field "${status_after}" "sandboxes")" == "1" ]] \
  || fail "agent openclaw status must expose active sandbox count"

policy_list_payload="$("${agent_bin}" openclaw policy list --json)"
python3 - "${policy_list_payload}" <<'PY' >/dev/null 2>&1
import json
import sys

payload = json.loads(sys.argv[1])
assert "discord:user:test" in (payload.get("dm_targets") or [])
assert "diagnostics.echo" in (payload.get("tools") or [])
PY
[[ $? -eq 0 ]] || fail "agent openclaw policy list must expose current allowlists"

"${agent_bin}" openclaw policy add tool diagnostics.ping >/tmp/agent-k9-policy-add.out \
  || fail "agent openclaw policy add tool must succeed"
grep -q '^diagnostics.ping$' "${agentic_root}/openclaw/config/tool_allowlist.txt" \
  || fail "policy add must append to tool allowlist file"

sandbox_ls_payload="$("${agent_bin}" openclaw sandbox ls --json)"
python3 - "${sandbox_ls_payload}" "${sandbox_id}" <<'PY' >/dev/null 2>&1
import json
import sys

payload = json.loads(sys.argv[1])
sandbox_id = sys.argv[2]
items = payload.get("sandboxes") or []
assert any(isinstance(item, dict) and item.get("sandbox_id") == sandbox_id for item in items)
PY
[[ $? -eq 0 ]] || fail "agent openclaw sandbox ls must expose active sandbox ids"

AGENT_NO_ATTACH=1 "${agent_bin}" openclaw sandbox attach "${sandbox_id}" >/tmp/agent-k9-sandbox-attach.out \
  || fail "agent openclaw sandbox attach must resolve sandbox workspace"
grep -q "prepared sandbox=${sandbox_id}" /tmp/agent-k9-sandbox-attach.out \
  || fail "sandbox attach dry-run must report the prepared sandbox"

destroy_payload="$("${agent_bin}" openclaw sandbox destroy "${sandbox_id}" --json)"
[[ "$(json_field "${destroy_payload}" "status")" == "destroyed" ]] \
  || fail "agent openclaw sandbox destroy must report destroyed status"

internal_list_after="$(docker exec "${toolbox_cid}" sh -lc "curl -fsS -H 'Authorization: Bearer ${claw_token}' http://openclaw-sandbox:8112/v1/internal/sandboxes")" \
  || fail "internal sandbox lifecycle list endpoint failed after destroy"
[[ "$(json_field "${internal_list_after}" "active")" == "0" ]] \
  || fail "sandbox destroy must remove the sandbox from the internal lifecycle API"

sandbox_ls_after="$("${agent_bin}" openclaw sandbox ls --json)"
python3 - "${sandbox_ls_after}" <<'PY' >/dev/null 2>&1
import json
import sys

payload = json.loads(sys.argv[1])
assert not (payload.get("sandboxes") or [])
PY
[[ $? -eq 0 ]] || fail "sandbox ls must be empty after destroy"

"${agent_bin}" doctor >/tmp/agent-k9-doctor.out 2>&1 || true
grep -q 'OK: openclaw module manifest is present and valid' /tmp/agent-k9-doctor.out \
  || fail "agent doctor must validate the openclaw module manifest"
grep -q 'OK: openclaw-sandbox internal lifecycle API is coherent with the operator registry' /tmp/agent-k9-doctor.out \
  || fail "agent doctor must validate the internal lifecycle API coherence"

ok "K9_openclaw_operator_planes passed"
