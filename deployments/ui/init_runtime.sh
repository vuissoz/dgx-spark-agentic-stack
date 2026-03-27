#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
AGENT_RUNTIME_UID="${AGENT_RUNTIME_UID:-1000}"
AGENT_RUNTIME_GID="${AGENT_RUNTIME_GID:-1000}"
AGENTIC_OPENHANDS_WORKSPACES_DIR="${AGENTIC_OPENHANDS_WORKSPACES_DIR:-${AGENTIC_ROOT}/openhands/workspaces}"
TEMPLATE_DIR="${REPO_ROOT}/examples/ui"
WORKSPACE_SEED_DIR="${AGENTIC_WORKSPACE_SEED_DIR:-${REPO_ROOT}/examples/workspace-default-python}"

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

env_value() {
  local env_file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "${env_file}" | head -n1
}

normalize_openhands_model() {
  local model="$1"
  if [[ "${model}" == */* ]]; then
    printf '%s\n' "${model}"
  else
    printf 'openai/%s\n' "${model}"
  fi
}

write_openhands_settings_if_missing() {
  local env_file="$1"
  local settings_file="$2"
  local model api_key base_url effective_model tmp_file

  if [[ -f "${settings_file}" ]]; then
    chmod 0660 "${settings_file}" || true
    log "preserve existing runtime file: ${settings_file}"
    return 0
  fi

  model="$(env_value "${env_file}" "LLM_MODEL")"
  api_key="$(env_value "${env_file}" "LLM_API_KEY")"
  base_url="$(env_value "${env_file}" "LLM_BASE_URL")"

  [[ -n "${model}" ]] || model="${AGENTIC_DEFAULT_MODEL:-nemotron-cascade-2:30b}"
  [[ -n "${api_key}" ]] || api_key="local-ollama"
  [[ -n "${base_url}" ]] || base_url="http://ollama-gate:11435/v1"
  effective_model="$(normalize_openhands_model "${model}")"

  tmp_file="$(mktemp "${settings_file}.tmp.XXXXXX")"
  python3 - "${effective_model}" "${api_key}" "${base_url}" >"${tmp_file}" <<'PY'
import json
import sys

llm_model, llm_api_key, llm_base_url = sys.argv[1:4]
payload = {
    "language": "en",
    "agent": "CodeActAgent",
    "llm_model": llm_model,
    "llm_api_key": llm_api_key,
    "llm_base_url": llm_base_url,
    "v1_enabled": True,
}
sys.stdout.write(json.dumps(payload, separators=(",", ":")))
sys.stdout.write("\n")
PY

  chmod 0660 "${tmp_file}"
  mv "${tmp_file}" "${settings_file}"
  log "created runtime file: ${settings_file}"
}

seed_openhands_workspace_if_missing() {
  local seed_basename destination

  [[ -d "${WORKSPACE_SEED_DIR}" ]] || {
    log "workspace seed skipped, source folder missing: ${WORKSPACE_SEED_DIR}"
    return 0
  }

  seed_basename="$(basename "${WORKSPACE_SEED_DIR}")"
  destination="${AGENTIC_OPENHANDS_WORKSPACES_DIR}/${seed_basename}"

  if [[ -e "${destination}" ]]; then
    log "preserve existing workspace seed: ${destination}"
    return 0
  fi

  cp -a "${WORKSPACE_SEED_DIR}" "${destination}"
  chmod -R u+rwX "${destination}" 2>/dev/null || true
  if [[ "${EUID}" -eq 0 ]]; then
    chown -R "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${destination}" || true
  fi
  log "seeded workspace folder: ${destination}"
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
  install -d -m 0770 "${AGENTIC_OPENHANDS_WORKSPACES_DIR}"

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
  migrate_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "OPENWEBUI_ENABLE_OLLAMA_API" "ENABLE_OLLAMA_API"
  migrate_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "OPENWEBUI_OLLAMA_BASE_URL" "OLLAMA_BASE_URL"
  migrate_env_key "${AGENTIC_ROOT}/openhands/config/openhands.env" "OPENHANDS_LLM_MODEL" "LLM_MODEL"
  migrate_env_key "${AGENTIC_ROOT}/openhands/config/openhands.env" "OPENHANDS_LLM_API_KEY" "LLM_API_KEY"
  ensure_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "WEBUI_ADMIN_EMAIL" "admin@local"
  ensure_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "WEBUI_ADMIN_PASSWORD" "change-me"
  ensure_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "OPENAI_API_KEY" "none"
  ensure_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "WEBUI_SECRET_KEY" "change-me-openwebui-secret"
  ensure_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "ENABLE_OLLAMA_API" "False"
  ensure_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "OLLAMA_BASE_URL" "http://ollama-gate:11435"
  ensure_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "OPENWEBUI_ENABLE_OLLAMA_API" "False"
  ensure_env_key "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "OPENWEBUI_OLLAMA_BASE_URL" "http://ollama-gate:11435"
  ensure_env_key "${AGENTIC_ROOT}/openhands/config/openhands.env" "LLM_API_KEY" "local-ollama"
  ensure_env_key "${AGENTIC_ROOT}/openhands/config/openhands.env" "LLM_MODEL" "${AGENTIC_DEFAULT_MODEL:-nemotron-cascade-2:30b}"
  ensure_env_key "${AGENTIC_ROOT}/openhands/config/openhands.env" "LLM_BASE_URL" "http://ollama-gate:11435/v1"
  seed_openhands_workspace_if_missing
  write_openhands_settings_if_missing \
    "${AGENTIC_ROOT}/openhands/config/openhands.env" \
    "${AGENTIC_ROOT}/openhands/state/settings.json"

  chmod 0600 "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "${AGENTIC_ROOT}/openhands/config/openhands.env"
  chmod 0660 "${AGENTIC_ROOT}/openhands/state/settings.json" || true

  if [[ "${EUID}" -eq 0 ]]; then
    chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" \
      "${AGENTIC_ROOT}/openwebui/data" \
      "${AGENTIC_ROOT}/openwebui/static" \
      "${AGENTIC_ROOT}/openhands/state" \
      "${AGENTIC_ROOT}/openhands/state/settings.json" \
      "${AGENTIC_ROOT}/openhands/logs" \
      "${AGENTIC_OPENHANDS_WORKSPACES_DIR}" \
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
      "${AGENTIC_OPENHANDS_WORKSPACES_DIR}" \
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
