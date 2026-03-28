#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
AGENTIC_OPENCLAW_WORKSPACES_DIR="${AGENTIC_OPENCLAW_WORKSPACES_DIR:-${AGENTIC_ROOT}/openclaw/workspaces}"
TEMPLATE_DIR="${REPO_ROOT}/examples/core"
OPTIONAL_TEMPLATE_DIR="${REPO_ROOT}/examples/optional"
AGENT_RUNTIME_UID="${AGENT_RUNTIME_UID:-1000}"
AGENT_RUNTIME_GID="${AGENT_RUNTIME_GID:-1000}"

log() {
  echo "INFO: $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ensure_secret_mode() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    chmod 0600 "${file}"
  fi
}

random_secret_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
    return 0
  fi
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

ensure_secret_file_if_missing() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    return 0
  fi
  umask 077
  random_secret_hex >"${file}"
  chmod 0600 "${file}" || true
  log "generated runtime secret: ${file}"
}

ensure_optional_secret_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    chmod 0600 "${file}" || true
    return 0
  fi
  : >"${file}"
  chmod 0600 "${file}" || true
  log "created optional runtime secret placeholder: ${file}"
}

copy_if_missing() {
  local src="$1"
  local dst="$2"
  local mode="$3"

  [[ -f "$src" ]] || die "template not found: ${src}"
  if [[ -f "$dst" ]]; then
    log "preserve existing runtime file: ${dst}"
    return 0
  fi

  install -D -m "$mode" "$src" "$dst"
  log "created runtime file: ${dst}"
}

sync_runtime_file() {
  local src="$1"
  local dst="$2"
  local mode="$3"

  [[ -f "$src" ]] || die "template not found: ${src}"
  install -D -m "$mode" "$src" "$dst"
}

ensure_openclaw_chat_status_plugin() {
  local plugin_src_dir="${OPTIONAL_TEMPLATE_DIR}/openclaw-chat-status-plugin"
  local plugin_dst_dir="${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/.openclaw/extensions/openclaw-chat-status"
  local plugin_runtime_dir="/state/cli/openclaw-home/.openclaw/extensions/openclaw-chat-status"
  local state_file="${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/openclaw.state.json"

  install -d -m 0770 "${plugin_dst_dir}" "${plugin_dst_dir}/skills/openclaw"
  sync_runtime_file "${plugin_src_dir}/package.json" "${plugin_dst_dir}/package.json" 0644
  sync_runtime_file "${plugin_src_dir}/openclaw.plugin.json" "${plugin_dst_dir}/openclaw.plugin.json" 0644
  sync_runtime_file "${plugin_src_dir}/index.ts" "${plugin_dst_dir}/index.ts" 0644
  sync_runtime_file "${plugin_src_dir}/skills/openclaw/SKILL.md" "${plugin_dst_dir}/skills/openclaw/SKILL.md" 0644

  python3 - "${state_file}" "${plugin_runtime_dir}" <<'PY'
import json
import pathlib
import sys

state_path = pathlib.Path(sys.argv[1])
plugin_dir = pathlib.Path(sys.argv[2])
payload = json.loads(state_path.read_text(encoding="utf-8"))

plugins = payload.setdefault("plugins", {})
allow = plugins.setdefault("allow", [])
if not isinstance(allow, list):
    allow = []
    plugins["allow"] = allow
if "openclaw-chat-status" not in allow:
    allow.append("openclaw-chat-status")

entries = plugins.setdefault("entries", {})
if not isinstance(entries, dict):
    entries = {}
    plugins["entries"] = entries
entry = entries.setdefault("openclaw-chat-status", {})
if not isinstance(entry, dict):
    entry = {}
    entries["openclaw-chat-status"] = entry
entry.setdefault("enabled", True)

installs = plugins.setdefault("installs", {})
if not isinstance(installs, dict):
    installs = {}
    plugins["installs"] = installs
install_record = installs.setdefault("openclaw-chat-status", {})
if not isinstance(install_record, dict):
    install_record = {}
    installs["openclaw-chat-status"] = install_record
install_record["source"] = "path"
install_record["sourcePath"] = str(plugin_dir)
install_record["installPath"] = str(plugin_dir)

state_path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")
PY
}

set_openclaw_runtime_permissions() {
  local openclaw_config_dir="${AGENTIC_ROOT}/openclaw/config"
  local openclaw_config_bridge_dir="${AGENTIC_ROOT}/openclaw/config/bridge"
  local openclaw_config_immutable_dir="${AGENTIC_ROOT}/openclaw/config/immutable"
  local openclaw_config_module_dir="${AGENTIC_ROOT}/openclaw/config/module"
  local openclaw_config_overlay_dir="${AGENTIC_ROOT}/openclaw/config/overlay"
  local openclaw_overlay_file="${AGENTIC_ROOT}/openclaw/config/overlay/openclaw.operator-overlay.json"
  local openclaw_bridge_file="${AGENTIC_ROOT}/openclaw/config/bridge/openclaw.provider-bridge.json"
  local openclaw_state_dir="${AGENTIC_ROOT}/openclaw/state"
  local openclaw_logs_dir="${AGENTIC_ROOT}/openclaw/logs"
  local openclaw_sandbox_state_dir="${AGENTIC_ROOT}/openclaw/sandbox/state"
  local openclaw_sandbox_workspaces_dir="${AGENTIC_ROOT}/openclaw/sandbox/workspaces"
  local openclaw_relay_state_dir="${AGENTIC_ROOT}/openclaw/relay/state"
  local openclaw_relay_logs_dir="${AGENTIC_ROOT}/openclaw/relay/logs"
  local openclaw_token="${AGENTIC_ROOT}/secrets/runtime/openclaw.token"
  local openclaw_webhook_secret="${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret"
  local openclaw_relay_telegram_secret="${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.telegram.secret"
  local openclaw_relay_whatsapp_secret="${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.whatsapp.secret"
  local openclaw_provider_telegram_token="${AGENTIC_ROOT}/secrets/runtime/telegram.bot_token"
  local openclaw_provider_discord_token="${AGENTIC_ROOT}/secrets/runtime/discord.bot_token"
  local openclaw_provider_slack_bot_token="${AGENTIC_ROOT}/secrets/runtime/slack.bot_token"
  local openclaw_provider_slack_app_token="${AGENTIC_ROOT}/secrets/runtime/slack.app_token"
  local openclaw_provider_slack_signing_secret="${AGENTIC_ROOT}/secrets/runtime/slack.signing_secret"

  if [[ "${EUID}" -eq 0 ]]; then
    chmod 0750 "${openclaw_config_dir}" "${openclaw_config_immutable_dir}" "${openclaw_config_module_dir}"
    chmod 0770 "${openclaw_config_bridge_dir}" "${openclaw_config_overlay_dir}"
    chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openclaw_config_bridge_dir}" "${openclaw_config_overlay_dir}" || true
    [[ -f "${openclaw_overlay_file}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openclaw_overlay_file}" || true
    [[ -f "${openclaw_bridge_file}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openclaw_bridge_file}" || true
    chown -R "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" \
      "${openclaw_state_dir}" \
      "${AGENTIC_OPENCLAW_WORKSPACES_DIR}" \
      "${openclaw_sandbox_state_dir}" \
      "${openclaw_sandbox_workspaces_dir}" \
      "${openclaw_relay_state_dir}" \
      "${openclaw_relay_logs_dir}" \
      "${openclaw_logs_dir}" || true
    [[ -f "${openclaw_token}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openclaw_token}" || true
    [[ -f "${openclaw_webhook_secret}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openclaw_webhook_secret}" || true
    [[ -f "${openclaw_relay_telegram_secret}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openclaw_relay_telegram_secret}" || true
    [[ -f "${openclaw_relay_whatsapp_secret}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openclaw_relay_whatsapp_secret}" || true
    [[ -f "${openclaw_provider_telegram_token}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openclaw_provider_telegram_token}" || true
    [[ -f "${openclaw_provider_discord_token}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openclaw_provider_discord_token}" || true
    [[ -f "${openclaw_provider_slack_bot_token}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openclaw_provider_slack_bot_token}" || true
    [[ -f "${openclaw_provider_slack_app_token}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openclaw_provider_slack_app_token}" || true
    [[ -f "${openclaw_provider_slack_signing_secret}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openclaw_provider_slack_signing_secret}" || true
    return 0
  fi

  chmod 0770 \
    "${openclaw_config_bridge_dir}" \
    "${openclaw_config_overlay_dir}" \
    "${openclaw_state_dir}" \
    "${AGENTIC_OPENCLAW_WORKSPACES_DIR}" \
    "${openclaw_sandbox_state_dir}" \
    "${openclaw_sandbox_workspaces_dir}" \
    "${openclaw_relay_state_dir}" \
    "${openclaw_relay_logs_dir}" \
    "${openclaw_logs_dir}"
  log "non-root runtime init: relaxed openclaw dirs permissions for userns compatibility"
}

iter_allowlist_entries() {
  local file="$1"
  awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line != "") {
        print line
      }
    }
  ' "${file}"
}

ensure_allowlist_baseline_entries() {
  local template_file="$1"
  local runtime_file="$2"
  local entry
  local missing_count=0

  [[ -f "${template_file}" ]] || die "allowlist template not found: ${template_file}"
  [[ -f "${runtime_file}" ]] || return 0

  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    if ! grep -Fxiq -- "${entry}" "${runtime_file}"; then
      printf '%s\n' "${entry}" >> "${runtime_file}"
      missing_count=$((missing_count + 1))
    fi
  done < <(iter_allowlist_entries "${template_file}")

  if (( missing_count > 0 )); then
    log "updated allowlist baseline: appended ${missing_count} missing entries to ${runtime_file}"
  fi
}

set_proxy_runtime_permissions() {
  local proxy_logs_dir="${AGENTIC_ROOT}/proxy/logs"
  local -a proxy_log_files=(
    "${proxy_logs_dir}/access.log"
    "${proxy_logs_dir}/cache.log"
  )

  chmod 0755 "${proxy_logs_dir}"

  if [[ "${EUID}" -eq 0 ]]; then
    chown 13:13 "${proxy_logs_dir}"
    local log_file
    for log_file in "${proxy_log_files[@]}"; do
      [[ -e "${log_file}" ]] || continue
      chown 13:13 "${log_file}" || true
      chmod 0640 "${log_file}" || true
    done
    return 0
  fi

  if command -v setfacl >/dev/null 2>&1; then
    # Squid opens log files before dropping from uid 0 to uid 13 (proxy).
    # With cap_drop=ALL, both uids need explicit write rights on bind-mounted logs.
    if ! setfacl -m u:0:rwx,u:13:rwx "${proxy_logs_dir}"; then
      log "non-root runtime init: unable to set ACL on ${proxy_logs_dir}; continuing"
      return 0
    fi
    if ! setfacl -d -m u:0:rwx,u:13:rwx "${proxy_logs_dir}"; then
      log "non-root runtime init: unable to set default ACL on ${proxy_logs_dir}; continuing"
      return 0
    fi

    local log_file
    for log_file in "${proxy_log_files[@]}"; do
      [[ -e "${log_file}" ]] || continue
      setfacl -m u:0:rw,u:13:rw "${log_file}" || true
    done

    log "non-root runtime init: applied ACL grants (uid 0 + uid 13) on ${proxy_logs_dir}"
    return 0
  fi

  log "non-root runtime init: setfacl not found, cannot enforce squid log ACLs on ${proxy_logs_dir}"
}

set_gate_runtime_permissions() {
  local gate_dir="${AGENTIC_ROOT}/gate"
  local gate_config_dir="${AGENTIC_ROOT}/gate/config"
  local gate_model_routes_file="${gate_config_dir}/model_routes.yml"
  local gate_state_dir="${AGENTIC_ROOT}/gate/state"
  local gate_logs_dir="${AGENTIC_ROOT}/gate/logs"
  local gate_mcp_dir="${AGENTIC_ROOT}/gate/mcp"
  local gate_mcp_state_dir="${AGENTIC_ROOT}/gate/mcp/state"
  local gate_mcp_logs_dir="${AGENTIC_ROOT}/gate/mcp/logs"
  local gate_mcp_token="${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token"
  local openai_key="${AGENTIC_ROOT}/secrets/runtime/openai.api_key"
  local openrouter_key="${AGENTIC_ROOT}/secrets/runtime/openrouter.api_key"
  local trtllm_models_dir="${AGENTIC_ROOT}/trtllm/models"
  local trtllm_state_dir="${AGENTIC_ROOT}/trtllm/state"
  local trtllm_logs_dir="${AGENTIC_ROOT}/trtllm/logs"

  if [[ "${EUID}" -eq 0 ]]; then
    chmod 0750 "${gate_dir}" "${gate_config_dir}"
    chmod 0750 "${gate_mcp_dir}"
    [[ -f "${gate_model_routes_file}" ]] && chmod 0640 "${gate_model_routes_file}" || true
    chmod 0770 "${gate_state_dir}" "${gate_logs_dir}" "${gate_mcp_state_dir}" "${gate_mcp_logs_dir}"
    chmod 0770 "${trtllm_models_dir}" "${trtllm_state_dir}" "${trtllm_logs_dir}"
    chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" \
      "${gate_config_dir}" \
      "${gate_state_dir}" "${gate_logs_dir}" "${gate_mcp_state_dir}" "${gate_mcp_logs_dir}" \
      "${trtllm_models_dir}" "${trtllm_state_dir}" "${trtllm_logs_dir}" || true
    [[ -f "${gate_model_routes_file}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${gate_model_routes_file}" || true
    # Normalize historical root-owned runtime files to avoid non-root startup failures.
    chown -R "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" \
      "${gate_state_dir}" "${gate_logs_dir}" "${gate_mcp_state_dir}" "${gate_mcp_logs_dir}" || true
    chmod -R u+rwX,g+rwX,o-rwx \
      "${gate_state_dir}" "${gate_logs_dir}" "${gate_mcp_state_dir}" "${gate_mcp_logs_dir}" || true
    [[ -f "${gate_mcp_token}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${gate_mcp_token}" || true
    [[ -f "${openai_key}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openai_key}" || true
    [[ -f "${openrouter_key}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openrouter_key}" || true
    return 0
  fi

  # Non-root local runs can include userns-remapped containers; relax only runtime test paths.
  chmod 0755 "${gate_dir}" "${gate_config_dir}"
  chmod 0755 "${gate_mcp_dir}"
  chmod 0770 "${gate_state_dir}" "${gate_logs_dir}" "${gate_mcp_state_dir}" "${gate_mcp_logs_dir}"
  log "non-root runtime init: relaxed gate dir permissions for userns compatibility"
}

ensure_gate_mode_file() {
  local mode_file="${AGENTIC_ROOT}/gate/state/llm_mode.json"
  local default_mode="${AGENTIC_LLM_MODE:-hybrid}"

  case "${default_mode}" in
    local|hybrid|remote) ;;
    *) default_mode="hybrid" ;;
  esac

  if [[ -f "${mode_file}" ]]; then
    return 0
  fi

  cat >"${mode_file}" <<JSON
{"mode":"${default_mode}","updated_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","updated_by":"init_runtime"}
JSON
  chmod 0640 "${mode_file}"
  log "created runtime file: ${mode_file}"
}

ensure_gate_quotas_file() {
  local quotas_file="${AGENTIC_ROOT}/gate/state/quotas_state.json"
  if [[ -f "${quotas_file}" ]]; then
    return 0
  fi
  cat >"${quotas_file}" <<JSON
{"version":1,"providers":{}}
JSON
  chmod 0640 "${quotas_file}"
  log "created runtime file: ${quotas_file}"
}

ensure_gate_mcp_token() {
  local token_file="${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token"
  local token
  if [[ -s "${token_file}" ]]; then
    chmod 0600 "${token_file}" || true
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    token="$(openssl rand -hex 24)"
  else
    token="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi

  printf '%s\n' "${token}" >"${token_file}"
  chmod 0600 "${token_file}"
  log "created runtime file: ${token_file}"
}

main() {
  install -d -m 0750 "${AGENTIC_ROOT}/ollama"
  install -d -m 0770 "${AGENTIC_ROOT}/ollama/models"
  install -d -m 0750 "${AGENTIC_ROOT}/gate"
  install -d -m 0750 "${AGENTIC_ROOT}/gate/config"
  install -d -m 0770 "${AGENTIC_ROOT}/gate/state"
  install -d -m 0770 "${AGENTIC_ROOT}/gate/logs"
  install -d -m 0750 "${AGENTIC_ROOT}/gate/mcp"
  install -d -m 0770 "${AGENTIC_ROOT}/gate/mcp/state"
  install -d -m 0770 "${AGENTIC_ROOT}/gate/mcp/logs"
  install -d -m 0750 "${AGENTIC_ROOT}/trtllm"
  install -d -m 0770 "${AGENTIC_ROOT}/trtllm/models"
  install -d -m 0770 "${AGENTIC_ROOT}/trtllm/state"
  install -d -m 0770 "${AGENTIC_ROOT}/trtllm/logs"
  install -d -m 0750 "${AGENTIC_ROOT}/dns"
  install -d -m 0750 "${AGENTIC_ROOT}/proxy"
  install -d -m 0750 "${AGENTIC_ROOT}/proxy/config"
  install -d -m 0755 "${AGENTIC_ROOT}/proxy/logs"
  install -d -m 0750 "${AGENTIC_ROOT}/openclaw"
  install -d -m 0750 "${AGENTIC_ROOT}/openclaw/config"
  install -d -m 0750 "${AGENTIC_ROOT}/openclaw/config/bridge"
  install -d -m 0750 "${AGENTIC_ROOT}/openclaw/config/immutable"
  install -d -m 0750 "${AGENTIC_ROOT}/openclaw/config/module"
  install -d -m 0770 "${AGENTIC_ROOT}/openclaw/config/overlay"
  install -d -m 0770 "${AGENTIC_ROOT}/openclaw/state"
  install -d -m 0770 "${AGENTIC_ROOT}/openclaw/state/approvals"
  install -d -m 0770 "${AGENTIC_ROOT}/openclaw/state/approvals/pending"
  install -d -m 0770 "${AGENTIC_ROOT}/openclaw/state/approvals/approved"
  install -d -m 0770 "${AGENTIC_ROOT}/openclaw/state/approvals/denied"
  install -d -m 0770 "${AGENTIC_ROOT}/openclaw/state/approvals/expired"
  install -d -m 0770 "${AGENTIC_ROOT}/openclaw/logs"
  install -d -m 0770 "${AGENTIC_OPENCLAW_WORKSPACES_DIR}"
  install -d -m 0750 "${AGENTIC_ROOT}/openclaw/relay"
  install -d -m 0770 "${AGENTIC_ROOT}/openclaw/relay/state"
  install -d -m 0770 "${AGENTIC_ROOT}/openclaw/relay/logs"
  install -d -m 0750 "${AGENTIC_ROOT}/openclaw/sandbox"
  install -d -m 0770 "${AGENTIC_ROOT}/openclaw/sandbox/state"
  install -d -m 0770 "${AGENTIC_ROOT}/openclaw/sandbox/workspaces"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets/runtime"

  copy_if_missing "${TEMPLATE_DIR}/model_routes.yml" "${AGENTIC_ROOT}/gate/config/model_routes.yml" 0640
  copy_if_missing "${TEMPLATE_DIR}/unbound.conf" "${AGENTIC_ROOT}/dns/unbound.conf" 0644
  copy_if_missing "${TEMPLATE_DIR}/squid.conf" "${AGENTIC_ROOT}/proxy/config/squid.conf" 0644
  copy_if_missing "${TEMPLATE_DIR}/allowlist.txt" "${AGENTIC_ROOT}/proxy/allowlist.txt" 0644
  copy_if_missing "${OPTIONAL_TEMPLATE_DIR}/openclaw.dm_allowlist.txt" "${AGENTIC_ROOT}/openclaw/config/dm_allowlist.txt" 0640
  copy_if_missing "${OPTIONAL_TEMPLATE_DIR}/openclaw.tool_allowlist.txt" "${AGENTIC_ROOT}/openclaw/config/tool_allowlist.txt" 0640
  copy_if_missing "${OPTIONAL_TEMPLATE_DIR}/openclaw.integration-profile.v1.json" "${AGENTIC_ROOT}/openclaw/config/integration-profile.v1.json" 0640
  copy_if_missing "${AGENTIC_ROOT}/openclaw/config/integration-profile.v1.json" "${AGENTIC_ROOT}/openclaw/config/integration-profile.current.json" 0640
  copy_if_missing "${OPTIONAL_TEMPLATE_DIR}/openclaw.operator-runtime.v1.json" "${AGENTIC_ROOT}/openclaw/config/operator-runtime.v1.json" 0640
  copy_if_missing "${OPTIONAL_TEMPLATE_DIR}/openclaw.module-manifest.v1.json" "${AGENTIC_ROOT}/openclaw/config/module/openclaw.module-manifest.v1.json" 0640
  copy_if_missing "${OPTIONAL_TEMPLATE_DIR}/openclaw.stack-config.v1.json" "${AGENTIC_ROOT}/openclaw/config/immutable/openclaw.stack-config.v1.json" 0640
  copy_if_missing "${OPTIONAL_TEMPLATE_DIR}/openclaw.provider-bridge.v1.json" "${AGENTIC_ROOT}/openclaw/config/bridge/openclaw.provider-bridge.json" 0640
  copy_if_missing "${OPTIONAL_TEMPLATE_DIR}/openclaw.operator-overlay.v1.json" "${AGENTIC_ROOT}/openclaw/config/overlay/openclaw.operator-overlay.json" 0640
  copy_if_missing "${OPTIONAL_TEMPLATE_DIR}/openclaw.relay_targets.json" "${AGENTIC_ROOT}/openclaw/config/relay_targets.json" 0640
  if [[ ! -f "${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/openclaw.state.json" ]]; then
    install -D -m 0600 /dev/null "${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/openclaw.state.json"
    printf '%s\n' '{}' >"${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/openclaw.state.json"
  fi
  ensure_openclaw_chat_status_plugin
  ensure_allowlist_baseline_entries "${TEMPLATE_DIR}/allowlist.txt" "${AGENTIC_ROOT}/proxy/allowlist.txt"
  chmod 0640 "${AGENTIC_ROOT}/gate/config/model_routes.yml"
  chmod 0644 "${AGENTIC_ROOT}/dns/unbound.conf"
  chmod 0644 "${AGENTIC_ROOT}/proxy/config/squid.conf"
  chmod 0644 "${AGENTIC_ROOT}/proxy/allowlist.txt"
  chmod 0644 \
    "${AGENTIC_ROOT}/openclaw/config/dm_allowlist.txt" \
    "${AGENTIC_ROOT}/openclaw/config/tool_allowlist.txt" \
    "${AGENTIC_ROOT}/openclaw/config/integration-profile.v1.json" \
    "${AGENTIC_ROOT}/openclaw/config/integration-profile.current.json" \
    "${AGENTIC_ROOT}/openclaw/config/operator-runtime.v1.json" \
    "${AGENTIC_ROOT}/openclaw/config/module/openclaw.module-manifest.v1.json" \
    "${AGENTIC_ROOT}/openclaw/config/bridge/openclaw.provider-bridge.json" \
    "${AGENTIC_ROOT}/openclaw/config/immutable/openclaw.stack-config.v1.json" \
    "${AGENTIC_ROOT}/openclaw/config/relay_targets.json"
  chmod 0640 "${AGENTIC_ROOT}/openclaw/config/overlay/openclaw.operator-overlay.json"
  python3 "${REPO_ROOT}/deployments/optional/openclaw_config_layers.py" validate-host-layout \
    --immutable-file "${AGENTIC_ROOT}/openclaw/config/immutable/openclaw.stack-config.v1.json" \
    --bridge-file "${AGENTIC_ROOT}/openclaw/config/bridge/openclaw.provider-bridge.json" \
    --overlay-file "${AGENTIC_ROOT}/openclaw/config/overlay/openclaw.operator-overlay.json" \
    --state-file "${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/openclaw.state.json"
  ensure_gate_mode_file
  ensure_gate_quotas_file
  ensure_gate_mcp_token
  ensure_optional_secret_file "${AGENTIC_ROOT}/secrets/runtime/huggingface.token"
  ensure_secret_file_if_missing "${AGENTIC_ROOT}/secrets/runtime/openclaw.token"
  ensure_secret_file_if_missing "${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret"
  ensure_secret_file_if_missing "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.telegram.secret"
  ensure_secret_file_if_missing "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.whatsapp.secret"
  [[ -f "${AGENTIC_ROOT}/secrets/runtime/telegram.bot_token" ]] || install -D -m 0600 /dev/null "${AGENTIC_ROOT}/secrets/runtime/telegram.bot_token"
  [[ -f "${AGENTIC_ROOT}/secrets/runtime/discord.bot_token" ]] || install -D -m 0600 /dev/null "${AGENTIC_ROOT}/secrets/runtime/discord.bot_token"
  [[ -f "${AGENTIC_ROOT}/secrets/runtime/slack.bot_token" ]] || install -D -m 0600 /dev/null "${AGENTIC_ROOT}/secrets/runtime/slack.bot_token"
  [[ -f "${AGENTIC_ROOT}/secrets/runtime/slack.app_token" ]] || install -D -m 0600 /dev/null "${AGENTIC_ROOT}/secrets/runtime/slack.app_token"
  [[ -f "${AGENTIC_ROOT}/secrets/runtime/slack.signing_secret" ]] || install -D -m 0600 /dev/null "${AGENTIC_ROOT}/secrets/runtime/slack.signing_secret"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/openai.api_key"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/openrouter.api_key"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/openclaw.token"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.telegram.secret"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.whatsapp.secret"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/telegram.bot_token"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/discord.bot_token"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/slack.bot_token"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/slack.app_token"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/slack.signing_secret"
  set_gate_runtime_permissions
  set_proxy_runtime_permissions
  set_openclaw_runtime_permissions
}

main "$@"
