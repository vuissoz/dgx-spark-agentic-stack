#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K17 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd python3

suffix="k17-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_AGENT_WORKSPACES_ROOT="${AGENTIC_ROOT}/agent-workspaces"
export AGENTIC_CLAUDE_WORKSPACES_DIR="${AGENTIC_AGENT_WORKSPACES_ROOT}/claude/workspaces"
export AGENTIC_CODEX_WORKSPACES_DIR="${AGENTIC_AGENT_WORKSPACES_ROOT}/codex/workspaces"
export AGENTIC_OPENCODE_WORKSPACES_DIR="${AGENTIC_AGENT_WORKSPACES_ROOT}/opencode/workspaces"
export AGENTIC_KILOCODE_WORKSPACES_DIR="${AGENTIC_AGENT_WORKSPACES_ROOT}/kilocode/workspaces"
export AGENTIC_VIBESTRAL_WORKSPACES_DIR="${AGENTIC_AGENT_WORKSPACES_ROOT}/vibestral/workspaces"
export AGENTIC_HERMES_WORKSPACES_DIR="${AGENTIC_AGENT_WORKSPACES_ROOT}/hermes/workspaces"
export AGENTIC_OPENHANDS_WORKSPACES_DIR="${AGENTIC_ROOT}/openhands/workspaces"
export AGENTIC_OPENCLAW_WORKSPACES_DIR="${AGENTIC_ROOT}/openclaw/workspaces"
export AGENTIC_PI_MONO_WORKSPACES_DIR="${AGENTIC_ROOT}/optional/pi-mono/workspaces"
export AGENTIC_GOOSE_WORKSPACES_DIR="${AGENTIC_ROOT}/optional/goose/workspaces"
export AGENTIC_OLLAMA_MODELS_LINK="${REPO_ROOT}/.runtime/${suffix}-ollama-models-link"
export AGENTIC_OLLAMA_MODELS_TARGET_DIR="${REPO_ROOT}/.runtime/${suffix}-ollama-models-target"
export OLLAMA_MODELS_DIR="${AGENTIC_OLLAMA_MODELS_LINK}"
export OLLAMA_HOST_PORT="$(pick_free_loopback_port 21434 200)"
export OPENCLAW_WEBHOOK_HOST_PORT="$(pick_free_loopback_port 28111 200)"
export OPENCLAW_GATEWAY_HOST_PORT="$(pick_free_loopback_port 28789 200)"
export OPENCLAW_GATEWAY_PROXY_METRICS_PORT="$(pick_free_loopback_port 29114 200)"
export OPENCLAW_RELAY_HOST_PORT="$(pick_free_loopback_port 28112 200)"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-k17-test"
export AGENTIC_EGRESS_NETWORK="agentic-k17-test-egress"
export AGENTIC_LLM_NETWORK="agentic-k17-test-llm"

cleanup() {
  "${agent_bin}" down core >/tmp/agent-k17-down-cleanup.out 2>&1 || true
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${REPO_ROOT}/compose/compose.core.yml" down >/tmp/agent-k17-compose-down-cleanup.out 2>&1 || true
  docker network rm "${AGENTIC_EGRESS_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_LLM_NETWORK}" >/dev/null 2>&1 || true
  if [[ -d "${AGENTIC_ROOT}" ]]; then
    find "${AGENTIC_ROOT}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${AGENTIC_ROOT}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
  fi
  rm -f "${AGENTIC_OLLAMA_MODELS_LINK}" >/dev/null 2>&1 || true
  if [[ -d "${AGENTIC_OLLAMA_MODELS_TARGET_DIR}" ]]; then
    find "${AGENTIC_OLLAMA_MODELS_TARGET_DIR}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${AGENTIC_OLLAMA_MODELS_TARGET_DIR}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${AGENTIC_OLLAMA_MODELS_TARGET_DIR}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"${agent_bin}" down core >/tmp/agent-k17-down-pre.out 2>&1 || true
docker network rm "${AGENTIC_EGRESS_NETWORK}" >/dev/null 2>&1 || true
docker network rm "${AGENTIC_NETWORK}" >/dev/null 2>&1 || true
docker network rm "${AGENTIC_LLM_NETWORK}" >/dev/null 2>&1 || true
"${REPO_ROOT}/deployments/core/init_runtime.sh"

agentic_root="${AGENTIC_ROOT}"
project_name="openclaw-recreate-k17"
workspace_host_dir="${AGENTIC_OPENCLAW_WORKSPACES_DIR:-${agentic_root}/openclaw/workspaces}/${project_name}"
core_compose_file="${REPO_ROOT}/compose/compose.core.yml"
openclaw_state_dir="${agentic_root}/openclaw/state/cli/openclaw-home/.openclaw"
telegram_state_file="${openclaw_state_dir}/telegram/recreate.json"
cron_state_file="${openclaw_state_dir}/cron/runs/recreate.json"
plugin_state_file="${openclaw_state_dir}/plugin-state/recreate.json"
relay_state_file="${agentic_root}/openclaw/relay/state/recreate.json"
sandbox_state_file="${agentic_root}/openclaw/sandbox/state/recreate.json"
workspace_marker_file="${workspace_host_dir}/README.md"
provider_bridge_status_file="${agentic_root}/openclaw/state/provider-bridge-status.json"
declare -a compose_cmd=(docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${core_compose_file}")

assert_relay_host_publication() {
  local container_id="$1"
  local phase="$2"
  local bindings_json
  bindings_json="$(docker inspect --format '{{json .NetworkSettings.Ports}}' "${container_id}")" \
    || fail "openclaw-relay Docker port inspection failed ${phase}"

  python3 - "${bindings_json}" "${OPENCLAW_RELAY_HOST_PORT}" <<'PY' \
    || fail "openclaw-relay must publish 8113 on 127.0.0.1:${OPENCLAW_RELAY_HOST_PORT} ${phase}"
import json
import sys

bindings = json.loads(sys.argv[1])
expected_port = sys.argv[2]
entries = bindings.get("8113/tcp") or []
assert any(
    isinstance(entry, dict)
    and entry.get("HostIp") == "127.0.0.1"
    and entry.get("HostPort") == expected_port
    for entry in entries
)
PY

  python3 - "${OPENCLAW_RELAY_HOST_PORT}" <<'PY' \
    || fail "openclaw-relay queue endpoint is not reachable through loopback ${phase}"
import sys
import urllib.request

with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/queue/status", timeout=10) as response:
    assert response.status == 200
PY
}

install -d -m 0700 "${agentic_root}/secrets/runtime"

printf '%s\n' "k17-openclaw-token-$(date +%s)" >"${agentic_root}/secrets/runtime/openclaw.token"
printf '%s\n' "k17-openclaw-webhook-$(date +%s)" >"${agentic_root}/secrets/runtime/openclaw.webhook_secret"
printf '%s\n' "123456:k17-telegram" >"${agentic_root}/secrets/runtime/telegram.bot_token"
printf '%s\n' "k17-discord" >"${agentic_root}/secrets/runtime/discord.bot_token"
printf '%s\n' "xoxb-k17-slack-bot" >"${agentic_root}/secrets/runtime/slack.bot_token"
printf '%s\n' "xapp-k17-slack-app" >"${agentic_root}/secrets/runtime/slack.app_token"
printf '%s\n' "k17-slack-signing" >"${agentic_root}/secrets/runtime/slack.signing_secret"
chmod 0600 \
  "${agentic_root}/secrets/runtime/openclaw.token" \
  "${agentic_root}/secrets/runtime/openclaw.webhook_secret" \
  "${agentic_root}/secrets/runtime/telegram.bot_token" \
  "${agentic_root}/secrets/runtime/discord.bot_token" \
  "${agentic_root}/secrets/runtime/slack.bot_token" \
  "${agentic_root}/secrets/runtime/slack.app_token" \
  "${agentic_root}/secrets/runtime/slack.signing_secret"

if [[ "${EUID}" -eq 0 ]]; then
  chown "${AGENT_RUNTIME_UID:-1000}:${AGENT_RUNTIME_GID:-1000}" \
    "${agentic_root}/secrets/runtime/openclaw.token" \
    "${agentic_root}/secrets/runtime/openclaw.webhook_secret" \
    "${agentic_root}/secrets/runtime/telegram.bot_token" \
    "${agentic_root}/secrets/runtime/discord.bot_token" \
    "${agentic_root}/secrets/runtime/slack.bot_token" \
    "${agentic_root}/secrets/runtime/slack.app_token" \
    "${agentic_root}/secrets/runtime/slack.signing_secret"
fi

"${compose_cmd[@]}" up -d --no-deps \
  egress-proxy \
  unbound \
  toolbox \
  openclaw-provider-bridge \
  openclaw-sandbox >/tmp/agent-k17-up-initial.out \
  || fail "compose up must start the OpenClaw prerequisites before recreation test"

provider_bridge_cid_before="$(require_service_container openclaw-provider-bridge)" || exit 1
sandbox_cid_before="$(require_service_container openclaw-sandbox)" || exit 1
wait_for_container_ready "${provider_bridge_cid_before}" 120 || fail "openclaw-provider-bridge did not become ready before recreation"
wait_for_container_ready "${sandbox_cid_before}" 120 || fail "openclaw-sandbox did not become ready before recreation"

"${compose_cmd[@]}" up -d --no-deps openclaw >/tmp/agent-k17-up-openclaw.out \
  || fail "compose up must start openclaw before recreation test"

openclaw_cid_before="$(require_service_container openclaw)" || exit 1
wait_for_container_ready "${openclaw_cid_before}" 120 || fail "openclaw did not become ready before recreation"

"${compose_cmd[@]}" up -d --no-deps openclaw-gateway openclaw-relay >/tmp/agent-k17-up-surfaces.out \
  || fail "compose up must start the OpenClaw surfaces before recreation test"

gateway_cid_before="$(require_service_container openclaw-gateway)" || exit 1
relay_cid_before="$(require_service_container openclaw-relay)" || exit 1
wait_for_container_ready "${gateway_cid_before}" 120 || fail "openclaw-gateway did not become ready before recreation"
wait_for_container_ready "${relay_cid_before}" 120 || fail "openclaw-relay did not become ready before recreation"
assert_relay_host_publication "${relay_cid_before}" "before recreation"

install -d -m 0750 \
  "$(dirname "${telegram_state_file}")" \
  "$(dirname "${cron_state_file}")" \
  "$(dirname "${plugin_state_file}")" \
  "$(dirname "${relay_state_file}")" \
  "$(dirname "${sandbox_state_file}")" \
  "${workspace_host_dir}"

printf '{"session":"survives-recreate"}\n' >"${telegram_state_file}"
printf '{"cron":"survives-recreate"}\n' >"${cron_state_file}"
printf '{"plugin":"survives-recreate"}\n' >"${plugin_state_file}"
printf '{"relay":"survives-recreate"}\n' >"${relay_state_file}"
printf '{"sandbox":"survives-recreate"}\n' >"${sandbox_state_file}"
printf 'container recreation must keep this workspace marker\n' >"${workspace_marker_file}"

[[ -s "${provider_bridge_status_file}" ]] || fail "provider bridge status file missing before recreation"

"${compose_cmd[@]}" down >/tmp/agent-k17-down.out \
  || fail "compose down failed during recreation test"
"${compose_cmd[@]}" up -d --no-deps \
  egress-proxy \
  unbound \
  toolbox \
  openclaw-provider-bridge \
  openclaw-sandbox >/tmp/agent-k17-up.out \
  || fail "compose up failed to restart the OpenClaw prerequisites during recreation test"

provider_bridge_cid_after="$(require_service_container openclaw-provider-bridge)" || exit 1
sandbox_cid_after="$(require_service_container openclaw-sandbox)" || exit 1
wait_for_container_ready "${provider_bridge_cid_after}" 120 || fail "openclaw-provider-bridge did not become ready after recreation"
wait_for_container_ready "${sandbox_cid_after}" 120 || fail "openclaw-sandbox did not become ready after recreation"

"${compose_cmd[@]}" up -d --no-deps openclaw >/tmp/agent-k17-up-openclaw-recreated.out \
  || fail "compose up failed to restart openclaw during recreation test"

openclaw_cid_after="$(require_service_container openclaw)" || exit 1
wait_for_container_ready "${openclaw_cid_after}" 120 || fail "openclaw did not become ready after recreation"

"${compose_cmd[@]}" up -d --no-deps openclaw-gateway openclaw-relay >/tmp/agent-k17-up-surfaces-recreated.out \
  || fail "compose up failed to restart the OpenClaw surfaces during recreation test"

gateway_cid_after="$(require_service_container openclaw-gateway)" || exit 1
relay_cid_after="$(require_service_container openclaw-relay)" || exit 1
wait_for_container_ready "${gateway_cid_after}" 120 || fail "openclaw-gateway did not become ready after recreation"
wait_for_container_ready "${relay_cid_after}" 120 || fail "openclaw-relay did not become ready after recreation"
assert_relay_host_publication "${relay_cid_after}" "after recreation"

[[ "${openclaw_cid_before}" != "${openclaw_cid_after}" ]] \
  || fail "openclaw container id must change after recreation"
[[ "${gateway_cid_before}" != "${gateway_cid_after}" ]] \
  || fail "openclaw-gateway container id must change after recreation"
[[ "${relay_cid_before}" != "${relay_cid_after}" ]] \
  || fail "openclaw-relay container id must change after recreation"
[[ "${sandbox_cid_before}" != "${sandbox_cid_after}" ]] \
  || fail "openclaw-sandbox container id must change after recreation"

grep -q '"session":"survives-recreate"' "${telegram_state_file}" \
  || fail "telegram state must survive container recreation"
grep -q '"cron":"survives-recreate"' "${cron_state_file}" \
  || fail "cron state must survive container recreation"
grep -q '"plugin":"survives-recreate"' "${plugin_state_file}" \
  || fail "plugin state must survive container recreation"
grep -q '"relay":"survives-recreate"' "${relay_state_file}" \
  || fail "relay state must survive container recreation"
grep -q '"sandbox":"survives-recreate"' "${sandbox_state_file}" \
  || fail "sandbox state must survive container recreation"
grep -q 'container recreation must keep this workspace marker' "${workspace_marker_file}" \
  || fail "workspace contents must survive container recreation"

[[ -s "${provider_bridge_status_file}" ]] || fail "provider bridge status file must survive container recreation"

docker exec "${openclaw_cid_after}" sh -lc 'test -f /state/cli/openclaw-home/.openclaw/telegram/recreate.json' \
  || fail "openclaw container must see telegram state after recreation"
docker exec "${openclaw_cid_after}" sh -lc 'test -f /state/cli/openclaw-home/.openclaw/cron/runs/recreate.json' \
  || fail "openclaw container must see cron state after recreation"
docker exec "${openclaw_cid_after}" sh -lc 'test -f /state/cli/openclaw-home/.openclaw/plugin-state/recreate.json' \
  || fail "openclaw container must see plugin state after recreation"
docker exec "${openclaw_cid_after}" sh -lc "test -f /workspace/${project_name}/README.md" \
  || fail "openclaw container must see workspace contents after recreation"
docker exec "${relay_cid_after}" sh -lc 'test -f /state/recreate.json' \
  || fail "openclaw-relay container must see relay state after recreation"
docker exec "${sandbox_cid_after}" sh -lc 'test -f /state/recreate.json' \
  || fail "openclaw-sandbox container must see sandbox state after recreation"

ok "K17_openclaw_container_recreation passed"
