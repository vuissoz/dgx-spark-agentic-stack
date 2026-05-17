#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K11 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd python3

"${agent_bin}" down core >/tmp/agent-k11-down-pre.out 2>&1 || true
"${REPO_ROOT}/deployments/core/init_runtime.sh"

agentic_root="${AGENTIC_ROOT}"
project_name="openclaw-init-k11"
workspace_dir="/workspace/${project_name}"
workspace_host_dir="${AGENTIC_OPENCLAW_WORKSPACES_DIR:-${agentic_root}/openclaw/workspaces}/${project_name}"
overlay_file="${agentic_root}/openclaw/config/overlay/openclaw.operator-overlay.json"
export AGENTIC_OPENCLAW_INIT_PROJECT="${project_name}"

install -d -m 0700 "${agentic_root}/secrets/runtime"

printf '%s\n' "k11-openclaw-token-$(date +%s)" >"${agentic_root}/secrets/runtime/openclaw.token"
printf '%s\n' "k11-openclaw-webhook-$(date +%s)" >"${agentic_root}/secrets/runtime/openclaw.webhook_secret"
printf '%s\n' "k11-discord" >"${agentic_root}/secrets/runtime/discord.bot_token"
printf '%s\n' "123456:k11-telegram" >"${agentic_root}/secrets/runtime/telegram.bot_token"
printf '%s\n' "xoxb-k11-slack-bot" >"${agentic_root}/secrets/runtime/slack.bot_token"
printf '%s\n' "xapp-k11-slack-app" >"${agentic_root}/secrets/runtime/slack.app_token"
chmod 0600 \
  "${agentic_root}/secrets/runtime/openclaw.token" \
  "${agentic_root}/secrets/runtime/openclaw.webhook_secret" \
  "${agentic_root}/secrets/runtime/discord.bot_token" \
  "${agentic_root}/secrets/runtime/telegram.bot_token" \
  "${agentic_root}/secrets/runtime/slack.bot_token" \
  "${agentic_root}/secrets/runtime/slack.app_token"

if [[ "${EUID}" -eq 0 ]]; then
  chown "${AGENT_RUNTIME_UID:-1000}:${AGENT_RUNTIME_GID:-1000}" \
    "${agentic_root}/secrets/runtime/openclaw.token" \
    "${agentic_root}/secrets/runtime/openclaw.webhook_secret" \
    "${agentic_root}/secrets/runtime/discord.bot_token" \
    "${agentic_root}/secrets/runtime/telegram.bot_token" \
    "${agentic_root}/secrets/runtime/slack.bot_token" \
    "${agentic_root}/secrets/runtime/slack.app_token"
fi

telegram_bot_token="123456:k11-telegram"
"${agent_bin}" openclaw init "${project_name}" >/tmp/agent-k11-init.out \
  || fail "agent openclaw init must succeed on a first-time stack"

grep -q '^OpenClaw managed init complete\.$' /tmp/agent-k11-init.out \
  || fail "managed init output must confirm completion"
grep -q "^workspace=${workspace_dir}$" /tmp/agent-k11-init.out \
  || fail "managed init output must report the stack workspace"
grep -q "^telegram_secret_file=${agentic_root}/secrets/runtime/telegram.bot_token$" /tmp/agent-k11-init.out \
  || fail "managed init output must report the telegram secret file when configured"
grep -q 'Do not use openclaw gateway run for normal stack operation' /tmp/agent-k11-init.out \
  || fail "managed init output must demote manual gateway run"

openclaw_cid="$(require_service_container openclaw)" || exit 1
provider_bridge_cid="$(require_service_container openclaw-provider-bridge)" || exit 1
wait_for_container_ready "${openclaw_cid}" 120 || fail "openclaw did not become ready after managed init"
wait_for_container_ready "${provider_bridge_cid}" 120 || fail "openclaw-provider-bridge did not become ready after managed init"

if timeout 10 docker exec "${openclaw_cid}" sh -lc 'openclaw gateway run' >/tmp/agent-k11-gateway-run.out 2>&1; then
  fail "manual openclaw gateway run must be blocked in the operator shell by default"
fi
grep -q "stack-managed OpenClaw blocks manual 'openclaw gateway run'" /tmp/agent-k11-gateway-run.out \
  || fail "manual gateway block must explain how to use the managed service"

[[ -d "${workspace_host_dir}" ]] || fail "managed init must create the host workspace directory"
[[ "$(tr -d '\r\n' <"${agentic_root}/secrets/runtime/telegram.bot_token")" == "${telegram_bot_token}" ]] \
  || fail "managed init must reuse the stack-managed telegram bot token secret file"

provider_bridge_status_file="${agentic_root}/openclaw/state/provider-bridge-status.json"
python3 - "${provider_bridge_status_file}" <<'PY' >/dev/null
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
provider = (payload.get("providers") or {}).get("telegram") or {}
assert provider.get("configured") is True
PY
[[ $? -eq 0 ]] || fail "managed init must leave the provider bridge reporting telegram as configured"

python3 - "${overlay_file}" "${workspace_dir}" <<'PY' >/dev/null
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert ((payload.get("agents") or {}).get("defaults") or {}).get("workspace") == sys.argv[2]
PY
[[ $? -eq 0 ]] || fail "managed init must persist the OpenClaw workspace in the validated overlay"

provider_allow_private_network="$(docker exec "${openclaw_cid}" sh -lc 'openclaw config get models.providers.custom-ollama-gate-11435.request.allowPrivateNetwork')"
[[ "${provider_allow_private_network}" == "true" ]] \
  || fail "managed init must allow the stack-managed OpenClaw provider to reach internal ollama-gate"

configured_workspace="$(docker exec "${openclaw_cid}" sh -lc 'openclaw config get agents.defaults.workspace')"
[[ "${configured_workspace}" == "${workspace_dir}" ]] \
  || fail "OpenClaw config must point at the stack-managed workspace after init"

agents_json="$(docker exec "${openclaw_cid}" sh -lc 'openclaw agents list --json')"
python3 - "${agents_json}" "${workspace_dir}" <<'PY' >/dev/null
import json
import sys

payload = json.loads(sys.argv[1])
expected = sys.argv[2]
assert isinstance(payload, list) and payload
assert any(isinstance(item, dict) and item.get("workspace") == expected for item in payload)
PY
[[ $? -eq 0 ]] || fail "managed init must reconcile at least one OpenClaw agent onto the stack workspace"

cat >"${overlay_file}" <<'JSON'
{
  "agents": {
    "defaults": {
      "workspace": "/state/cli/openclaw-home/.openclaw/workspace"
    }
  },
  "commands": {
    "native": "auto"
  }
}
JSON
chmod 0640 "${overlay_file}"

"${agent_bin}" openclaw init "${project_name}" >/tmp/agent-k11-repair.out \
  || fail "agent openclaw init must succeed as a repair path after workspace drift"

grep -q "^workspace=${workspace_dir}$" /tmp/agent-k11-repair.out \
  || fail "repair output must keep the same managed workspace"
grep -q '"workspace_changed":true' /tmp/agent-k11-repair.out \
  || fail "repair output must report that the broken workspace drift was corrected"

python3 - "${overlay_file}" "${workspace_dir}" <<'PY' >/dev/null
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert ((payload.get("agents") or {}).get("defaults") or {}).get("workspace") == sys.argv[2]
PY
[[ $? -eq 0 ]] || fail "repair must restore the overlay workspace back under /workspace"

repaired_workspace="$(docker exec "${openclaw_cid}" sh -lc 'openclaw config get agents.defaults.workspace')"
[[ "${repaired_workspace}" == "${workspace_dir}" ]] \
  || fail "repair must restore the OpenClaw config workspace"

repaired_agents_json="$(docker exec "${openclaw_cid}" sh -lc 'openclaw agents list --json')"
python3 - "${repaired_agents_json}" "${workspace_dir}" <<'PY' >/dev/null
import json
import sys

payload = json.loads(sys.argv[1])
expected = sys.argv[2]
assert isinstance(payload, list) and payload
assert any(isinstance(item, dict) and item.get("workspace") == expected for item in payload)
PY
[[ $? -eq 0 ]] || fail "repair must keep an OpenClaw agent on the managed workspace"

ok "K11_openclaw_init passed"
