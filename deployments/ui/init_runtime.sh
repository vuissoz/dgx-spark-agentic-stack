#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
AGENT_RUNTIME_UID="${AGENT_RUNTIME_UID:-1000}"
AGENT_RUNTIME_GID="${AGENT_RUNTIME_GID:-1000}"
TEMPLATE_DIR="${REPO_ROOT}/examples/ui"

log() {
  echo "INFO: $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

copy_if_missing() {
  local src="$1"
  local dst="$2"
  local mode="$3"

  [[ -f "${src}" ]] || die "template not found: ${src}"
  if [[ -f "${dst}" ]]; then
    log "preserve existing runtime file: ${dst}"
    return 0
  fi

  install -D -m "${mode}" "${src}" "${dst}"
  log "created runtime file: ${dst}"
}

ensure_env_key() {
  local env_file="$1"
  local key="$2"
  local value="$3"

  [[ -f "${env_file}" ]] || return 0
  if ! grep -Eq "^${key}=" "${env_file}"; then
    printf '%s=%s\n' "${key}" "${value}" >> "${env_file}"
    log "added missing ${key} to ${env_file}"
  fi
}

migrate_env_key() {
  local env_file="$1"
  local legacy_key="$2"
  local target_key="$3"
  local legacy_value

  [[ -f "${env_file}" ]] || return 0
  if grep -Eq "^${target_key}=" "${env_file}"; then
    return 0
  fi

  legacy_value="$(sed -n "s/^${legacy_key}=//p" "${env_file}" | head -n1)"
  if [[ -n "${legacy_value}" ]]; then
    printf '%s=%s\n' "${target_key}" "${legacy_value}" >> "${env_file}"
    log "migrated ${legacy_key} -> ${target_key} in ${env_file}"
  fi
}

main() {
  install -d -m 0750 "${AGENTIC_ROOT}/openwebui"
  install -d -m 0750 "${AGENTIC_ROOT}/openwebui/config"
  install -d -m 0770 "${AGENTIC_ROOT}/openwebui/data"
  install -d -m 0770 "${AGENTIC_ROOT}/openwebui/static"

  install -d -m 0750 "${AGENTIC_ROOT}/openhands"
  install -d -m 0750 "${AGENTIC_ROOT}/openhands/config"
  install -d -m 0770 "${AGENTIC_ROOT}/openhands/state"
  install -d -m 0770 "${AGENTIC_ROOT}/openhands/logs"
  install -d -m 0770 "${AGENTIC_ROOT}/openhands/workspaces"

  install -d -m 0750 "${AGENTIC_ROOT}/comfyui"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/models"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/input"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/output"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/user"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/custom_nodes"

  copy_if_missing "${TEMPLATE_DIR}/openwebui.env" "${AGENTIC_ROOT}/openwebui/config/openwebui.env" 0600
  copy_if_missing "${TEMPLATE_DIR}/openhands.env" "${AGENTIC_ROOT}/openhands/config/openhands.env" 0600
  migrate_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "OPENWEBUI_ADMIN_EMAIL" "WEBUI_ADMIN_EMAIL"
  migrate_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "OPENWEBUI_ADMIN_PASSWORD" "WEBUI_ADMIN_PASSWORD"
  migrate_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "OPENWEBUI_OPENAI_API_KEY" "OPENAI_API_KEY"
  migrate_env_key "${AGENTIC_ROOT}/openhands/config/openhands.env" "OPENHANDS_LLM_MODEL" "LLM_MODEL"
  migrate_env_key "${AGENTIC_ROOT}/openhands/config/openhands.env" "OPENHANDS_LLM_API_KEY" "LLM_API_KEY"
  ensure_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "WEBUI_ADMIN_EMAIL" "admin@local"
  ensure_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "WEBUI_ADMIN_PASSWORD" "change-me"
  ensure_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "OPENAI_API_KEY" "none"
  ensure_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "WEBUI_SECRET_KEY" "change-me-openwebui-secret"
  ensure_env_key "${AGENTIC_ROOT}/openhands/config/openhands.env" "LLM_API_KEY" "local-ollama"
  ensure_env_key "${AGENTIC_ROOT}/openhands/config/openhands.env" "LLM_MODEL" "${AGENTIC_DEFAULT_MODEL:-qwen3:0.6b}"

  chmod 0600 "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "${AGENTIC_ROOT}/openhands/config/openhands.env"

  if [[ "${EUID}" -eq 0 ]]; then
    chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" \
      "${AGENTIC_ROOT}/openwebui/data" \
      "${AGENTIC_ROOT}/openwebui/static" \
      "${AGENTIC_ROOT}/openhands/state" \
      "${AGENTIC_ROOT}/openhands/logs" \
      "${AGENTIC_ROOT}/openhands/workspaces" \
      "${AGENTIC_ROOT}/comfyui/models" \
      "${AGENTIC_ROOT}/comfyui/input" \
      "${AGENTIC_ROOT}/comfyui/output" \
      "${AGENTIC_ROOT}/comfyui/user" \
      "${AGENTIC_ROOT}/comfyui/custom_nodes"
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    chmod 0770 "${AGENTIC_ROOT}/openwebui/data" \
      "${AGENTIC_ROOT}/openwebui/static" \
      "${AGENTIC_ROOT}/openhands/state" \
      "${AGENTIC_ROOT}/openhands/logs" \
      "${AGENTIC_ROOT}/openhands/workspaces" \
      "${AGENTIC_ROOT}/comfyui/models" \
      "${AGENTIC_ROOT}/comfyui/input" \
      "${AGENTIC_ROOT}/comfyui/output" \
      "${AGENTIC_ROOT}/comfyui/user" \
      "${AGENTIC_ROOT}/comfyui/custom_nodes"
    log "non-root runtime init: relaxed UI runtime dirs for userns compatibility"

    if [[ -f "${AGENTIC_ROOT}/openwebui/data/webui.db" && ! -w "${AGENTIC_ROOT}/openwebui/data/webui.db" ]]; then
      log "non-root notice: ${AGENTIC_ROOT}/openwebui/data/webui.db is not writable by current user; fix ownership or rotate the file if OpenWebUI fails to start"
    fi
  fi
}

main "$@"
