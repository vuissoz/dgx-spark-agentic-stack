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
GIT_FORGE_ADMIN_USER="${GIT_FORGE_ADMIN_USER:-system-manager}"

log() {
  echo "INFO: $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ensure_secret_mode() {
  local file="$1"
  ensure_secret_path_is_file "${file}"
  if [[ -f "${file}" ]]; then
    chmod 0600 "${file}"
  fi
}

ensure_secret_path_is_file() {
  local file="$1"
  local file_type
  if [[ -e "${file}" && ! -f "${file}" ]]; then
    file_type="$(stat -c '%F' "${file}" 2>/dev/null || printf 'non-regular path')"
    die "secret path must be a regular file, found ${file_type}: ${file}; remove the path and re-run runtime init"
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
  ensure_secret_path_is_file "${file}"
  if [[ -f "${file}" ]]; then
    return 0
  fi
  umask 077
  random_secret_hex >"${file}"
  chmod 0600 "${file}" || true
  log "generated runtime secret: ${file}"
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

remove_env_key() {
  local env_file="$1"
  local key="$2"
  local tmp_file

  [[ -f "${env_file}" ]] || return 0
  grep -Eq "^${key}=" "${env_file}" || return 0

  tmp_file="$(mktemp "${env_file}.tmp.XXXXXX")"
  chmod 0600 "${tmp_file}"
  awk -v prefix="${key}=" 'index($0, prefix) != 1 { print }' "${env_file}" >"${tmp_file}"
  mv "${tmp_file}" "${env_file}"
  chmod 0640 "${env_file}" || true
  log "removed deprecated sensitive key ${key} from ${env_file}"
}

write_secret_value() {
  local file="$1"
  local value="$2"
  local tmp_file

  [[ -n "${value}" ]] || die "refusing to write an empty secret: ${file}"
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] \
    || die "secret value must be a single line: ${file}"

  tmp_file="$(mktemp "${file}.tmp.XXXXXX")"
  chmod 0600 "${tmp_file}"
  printf '%s\n' "${value}" >"${tmp_file}"
  mv "${tmp_file}" "${file}"
  chmod 0600 "${file}"
}

initialize_comfyui_auth_secret() {
  local secret_file="${AGENTIC_ROOT}/secrets/runtime/comfyui.auth_password"
  local runtime_env="${AGENTIC_ROOT}/deployments/runtime.env"
  local current_value=""
  local legacy_value=""

  ensure_secret_path_is_file "${secret_file}"
  if [[ -s "${secret_file}" ]]; then
    current_value="$(tr -d '\r\n' <"${secret_file}")"
  fi

  if [[ -f "${runtime_env}" ]]; then
    legacy_value="$(env_value "${runtime_env}" "COMFYUI_AUTH_PASSWORD")"
  fi

  if [[ -n "${current_value}" && "${current_value}" != "change-me" ]]; then
    chmod 0600 "${secret_file}"
  elif [[ -n "${legacy_value}" && "${legacy_value}" != "change-me" ]]; then
    write_secret_value "${secret_file}" "${legacy_value}"
    log "migrated ComfyUI authentication password to file-backed runtime secret"
  else
    write_secret_value "${secret_file}" "$(random_secret_hex)"
    log "generated ComfyUI authentication password file: ${secret_file}"
  fi

  # The password used to be interpolated into Compose from runtime.env. Remove
  # every legacy occurrence after migration so releases and future shells do
  # not retain the sensitive value.
  remove_env_key "${runtime_env}" "COMFYUI_AUTH_PASSWORD"

  if [[ "${EUID}" -eq 0 ]]; then
    chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${secret_file}"
  fi
  chmod 0700 "${AGENTIC_ROOT}/secrets/runtime"
  chmod 0600 "${secret_file}"
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

  [[ -n "${model}" ]] || model="${AGENTIC_AGENT_DEFAULT_MODEL:-${AGENTIC_DEFAULT_MODEL:-nemotron-cascade-2:30b}}"
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

prepare_forgejo_volumes() {
  local forgejo_state_dir="${AGENTIC_ROOT}/optional/git/state"
  local forgejo_state_leaf
  # Pre-create every individual Compose mountpoint. Otherwise Docker creates
  # absent bind sources as root after this initializer has run.
  for forgejo_state_leaf in \
    git tmp home data repo-archive packages actions_log actions_artifacts \
    queues jwt indexers ssh forgejo custom/conf; do
    install -d -m 0775 "${forgejo_state_dir}/${forgejo_state_leaf}"
  done

  # Set permissive permissions for Forgejo queues directory to allow container to manage locks
  if [[ -d "${AGENTIC_ROOT}/optional/git/state/queues" ]]; then
    find "${AGENTIC_ROOT}/optional/git/state/queues" -type d -exec chmod 775 {} + 2>/dev/null || true
    find "${AGENTIC_ROOT}/optional/git/state/queues" -type f -exec chmod 664 {} + 2>/dev/null || true
    rm -f "${AGENTIC_ROOT}/optional/git/state/queues/common/LOCK" 2>/dev/null || true
    log "prepared Forgejo queues directory for rootless container"
  fi

  # Ensure config directory has correct permissions
  if [[ -d "${AGENTIC_ROOT}/optional/git/config" ]]; then
    chmod 775 "${AGENTIC_ROOT}/optional/git/config" 2>/dev/null || true
    if [[ -f "${AGENTIC_ROOT}/optional/git/config/app.ini" ]]; then
      chmod 664 "${AGENTIC_ROOT}/optional/git/config/app.ini" 2>/dev/null || true
    fi
    log "prepared Forgejo config directory for rootless container"
  fi

  # Ensure custom directory has correct permissions (needed for rootless)
  if [[ -d "${AGENTIC_ROOT}/optional/git/state" ]]; then
    find "${AGENTIC_ROOT}/optional/git/state" -type d -exec chmod 775 {} + 2>/dev/null || true
    find "${AGENTIC_ROOT}/optional/git/state" -type f -exec chmod 664 {} + 2>/dev/null || true
    log "prepared Forgejo state directory for rootless container"
  fi

  # Create and distribute Forgejo SSH host key for agents
  if [[ ! -f "${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts" ]]; then
    log "creating Forgejo SSH host key file"
    install -d -m 0750 "${AGENTIC_ROOT}/secrets/ssh"
    cat > "${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts" << 'EOF'
optional-forgejo ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC+mvCpIsDts8QLg8Ake3nK22Pk1rmdAVTfLAOF0bVcqR61Ekz+DqqvZDETdQ8FE9BtYOkJD4c9d0XNS5BLkicAI2Uea9OzbKclkGuSm71QLeKdSt6GvEiKQT6ys2xTOzQtzoWetIZ/chnVGwnOtpZwS1HursaVzOYliepIR769fOfbKvjJqm2mJ81V+/m2kcp3RULFn7sWMY8zKolvLMrC7T6JWh736xhC4Th2MGO9+sBvEC4gX956UeFygEu1qoW44rOJanmCM52LqCapSZILQLsyMfvcd8exiM4LVwCod4XG26/gzxB3sr6IE/9uABi32Hc9z2qJXUW3gHiu2rIUIjxH0ftr+EPqqPG9jYynkrGq6x2F+DD8Jqv9f9LII3vZdsfozTbP3O8wE86C+1E1DxkGDyueZlhhC1nqLIwv3s9R5mIjTiCdBYr7ztFZ4kPtGNs17DR4VxAiLn8ST5wvRYrZw1L5CDL9AyJzVAtzkgZWWm2e5IYfPCCa5otaXk4tPdacnPEQXi2mjjWvWgoYVG76xZb/cz2POX6BxfPYH7PkYXRYk/a4okNpZbnqlNyQFzYqunHNylO398GeKBnehUP2tLjBMwmnDC3oAGjgMDfOjUpYXCG1rz1P/80fgvbVI1HIlZzGtJWckYuhfOw7IFxqopLL5Iab58jlmoMAew==
EOF
    chmod 644 "${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts"
    if [[ "${EUID}" -eq 0 ]]; then
      chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts"
    fi
    log "created Forgejo SSH host key for agents"
  fi

  # Forgejo's rootless image can create nested state paths as root during its
  # entrypoint. Repair only the Forgejo runtime roots before the next start so
  # the configured non-root service user can write repositories and queues.
  if [[ "${AGENTIC_PROFILE:-strict-prod}" == "rootless-dev" && "${EUID}" -ne 0 ]]; then
    command -v docker >/dev/null 2>&1 \
      || die "docker command is required to repair Forgejo ownership in rootless-dev"
    docker run --rm \
      -v "${AGENTIC_ROOT}/optional/git/state:/repair/state" \
      -v "${AGENTIC_ROOT}/optional/git/config:/repair/config" \
      busybox:1.36.1 sh -lc "
        set -eu
        chown -R ${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID} /repair/state /repair/config || true
        # Rootless user namespaces can preserve host root ownership despite
        # chown. The Forgejo process still needs a writable bind mount.
        chmod -R a+rwX /repair/state /repair/config
      "
    log "repaired Forgejo state/config permissions for rootless container"
  fi
}

repair_rootless_openhands_layout() {
  local target_uid="${AGENT_RUNTIME_UID:-$(id -u)}"
  local target_gid="${AGENT_RUNTIME_GID:-$(id -g)}"
  local needs_repair=0
  local path
  local -a repair_paths=(
    "${AGENTIC_ROOT}/openhands/state"
    "${AGENTIC_ROOT}/openhands/state/home"
    "${AGENTIC_ROOT}/openhands/logs"
    "${AGENTIC_OPENHANDS_WORKSPACES_DIR}"
  )

  [[ "${AGENTIC_PROFILE:-strict-prod}" == "rootless-dev" ]] || return 0
  [[ "${EUID}" -ne 0 ]] || return 0

  for path in "${repair_paths[@]}"; do
    [[ -e "${path}" ]] || continue
    if [[ ! -r "${path}" ]] || [[ ! -w "${path}" ]] || [[ -n "$(find "${path}" -mindepth 0 \( ! -readable -o ! -writable \) -print -quit 2>/dev/null || true)" ]]; then
      needs_repair=1
      break
    fi
  done
  [[ "${needs_repair}" -eq 1 ]] || return 0

  command -v docker >/dev/null 2>&1 \
    || die "docker command is required to repair OpenHands ownership in rootless-dev"

  docker run --rm \
    -v "${AGENTIC_ROOT}/openhands:/repair/openhands" \
    busybox:1.36.1 sh -lc "
      set -eu
      for path in /repair/openhands/state /repair/openhands/logs /repair/openhands/workspaces; do
        [ -e \"\${path}\" ] || continue
        chown -R ${target_uid}:${target_gid} \"\${path}\" || true
        chmod -R a+rwX \"\${path}\"
      done
    " || die "failed to repair OpenHands ownership for rootless-dev runtime"

  log "repaired OpenHands ownership with containerized chown (uid=${target_uid} gid=${target_gid})"
}

repair_openhands_state_permissions() {
  local state_root="${AGENTIC_ROOT}/openhands/state"

  [[ -d "${state_root}" ]] || return 0

  find "${state_root}" -type d -exec chmod g+s {} + 2>/dev/null || true
  find "${state_root}" -type d -exec chmod g+rwx {} + 2>/dev/null || true
  find "${state_root}" -type f -exec chmod g+rw {} + 2>/dev/null || true
  log "prepared OpenHands state permissions for native uid + host runtime group access"
}

main() {
  local git_forge_secret
  local -a git_forge_accounts=(
    "${GIT_FORGE_ADMIN_USER}"
    openclaw
    openhands
    comfyui
    claude
    codex
    opencode
    vibestral
    hermes
    pi-mono
    goose
  )

  install -d -m 0750 "${AGENTIC_ROOT}/openwebui"
  install -d -m 0750 "${AGENTIC_ROOT}/openwebui/config"
  install -d -m 0770 "${AGENTIC_ROOT}/openwebui/data"
  install -d -m 0770 "${AGENTIC_ROOT}/openwebui/static"

  install -d -m 0750 "${AGENTIC_ROOT}/openhands"
  install -d -m 0750 "${AGENTIC_ROOT}/openhands/config"
  install -d -m 0770 "${AGENTIC_ROOT}/openhands/state"
  install -d -m 0770 "${AGENTIC_ROOT}/openhands/state/home"
  install -d -m 0770 "${AGENTIC_ROOT}/openhands/logs"
  install -d -m 0770 "${AGENTIC_OPENHANDS_WORKSPACES_DIR}"

  install -d -m 0750 "${AGENTIC_ROOT}/comfyui"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/models"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/input"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/output"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/user"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/custom_nodes"

  install -d -m 0750 "${AGENTIC_ROOT}/optional"
  install -d -m 0750 "${AGENTIC_ROOT}/optional/git"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/git/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/git/config"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/git/bootstrap"

  install -d -m 0700 "${AGENTIC_ROOT}/secrets"
  install -d -m 0750 "${AGENTIC_ROOT}/secrets/ssh"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets/ssh/openhands"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets/ssh/comfyui"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets/runtime"
  install -d -m 0750 "${AGENTIC_ROOT}/secrets/runtime/git-forge"

  initialize_comfyui_auth_secret

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
  ensure_env_key "${AGENTIC_ROOT}/openhands/config/openhands.env" "LLM_MODEL" "${AGENTIC_AGENT_DEFAULT_MODEL:-${AGENTIC_DEFAULT_MODEL:-nemotron-cascade-2:30b}}"
  ensure_env_key "${AGENTIC_ROOT}/openhands/config/openhands.env" "LLM_BASE_URL" "http://ollama-gate:11435/v1"
  seed_openhands_workspace_if_missing
  repair_rootless_openhands_layout
  write_openhands_settings_if_missing \
    "${AGENTIC_ROOT}/openhands/config/openhands.env" \
    "${AGENTIC_ROOT}/openhands/state/settings.json"
  repair_openhands_state_permissions

  for git_forge_secret in "${git_forge_accounts[@]}"; do
    ensure_secret_file_if_missing "${AGENTIC_ROOT}/secrets/runtime/git-forge/${git_forge_secret}.password"
    ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/git-forge/${git_forge_secret}.password"
    chmod 0640 "${AGENTIC_ROOT}/secrets/runtime/git-forge/${git_forge_secret}.password" || true
  done

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
      "${AGENTIC_ROOT}/comfyui/custom_nodes" \
      "${AGENTIC_ROOT}/secrets/ssh/openhands" \
      "${AGENTIC_ROOT}/secrets/ssh/comfyui" \
      "${AGENTIC_ROOT}/optional/git/state" \
      "${AGENTIC_ROOT}/optional/git/config" \
      "${AGENTIC_ROOT}/optional/git/bootstrap"
    for git_forge_secret in "${git_forge_accounts[@]}"; do
      chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${AGENTIC_ROOT}/secrets/runtime/git-forge/${git_forge_secret}.password" || true
      chmod 0640 "${AGENTIC_ROOT}/secrets/runtime/git-forge/${git_forge_secret}.password" || true
    done
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
      "${AGENTIC_ROOT}/comfyui/custom_nodes" \
      "${AGENTIC_ROOT}/secrets/ssh/openhands" \
      "${AGENTIC_ROOT}/secrets/ssh/comfyui" \
      "${AGENTIC_ROOT}/optional/git/state" \
      "${AGENTIC_ROOT}/optional/git/config" \
      "${AGENTIC_ROOT}/optional/git/bootstrap"
    log "non-root runtime init: relaxed UI runtime dirs for userns compatibility"

    # Prepare Forgejo volumes for rootless container
    prepare_forgejo_volumes

    if [[ -f "${AGENTIC_ROOT}/openwebui/data/webui.db" && ! -w "${AGENTIC_ROOT}/openwebui/data/webui.db" ]]; then
      log "non-root notice: ${AGENTIC_ROOT}/openwebui/data/webui.db is not writable by current user; fix ownership or rotate the file if OpenWebUI fails to start"
    fi
  fi
}

main "$@"
