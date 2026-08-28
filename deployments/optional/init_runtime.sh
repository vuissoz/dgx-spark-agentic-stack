#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
AGENTIC_PI_MONO_WORKSPACES_DIR="${AGENTIC_PI_MONO_WORKSPACES_DIR:-${AGENTIC_ROOT}/optional/pi-mono/workspaces}"
AGENTIC_GOOSE_WORKSPACES_DIR="${AGENTIC_GOOSE_WORKSPACES_DIR:-${AGENTIC_ROOT}/optional/goose/workspaces}"
TEMPLATE_DIR="${REPO_ROOT}/examples/optional"
GIT_FORGE_ADMIN_USER="${GIT_FORGE_ADMIN_USER:-system-manager}"

log() {
  echo "INFO: $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

repair_rootless_n8n_layout() {
  local n8n_root="${AGENTIC_ROOT}/optional/n8n"
  local first_unwritable=""
  local scoped_path=""
  local target_uid="${AGENT_RUNTIME_UID:-$(id -u)}"
  local target_gid="${AGENT_RUNTIME_GID:-$(id -g)}"

  [[ "${EUID}" -ne 0 ]] || return 0
  [[ -d "${n8n_root}" ]] || return 0

  for scoped_path in "${n8n_root}/data" "${n8n_root}/custom" "${n8n_root}/logs"; do
    [[ -d "${scoped_path}" ]] || continue
    first_unwritable="$(find "${scoped_path}" -mindepth 0 ! -writable -print -quit 2>/dev/null || true)"
    [[ -z "${first_unwritable}" ]] || break
  done
  [[ -n "${first_unwritable}" ]] || return 0

  command -v docker >/dev/null 2>&1 \
    || die "docker is required to repair legacy n8n ownership (first unwritable path: ${first_unwritable})"
  docker run --rm --network none \
    -v "${n8n_root}/data:/repair/data" \
    -v "${n8n_root}/custom:/repair/custom" \
    -v "${n8n_root}/logs:/repair/logs" \
    busybox:1.36.1 sh -lc \
    "chown -R ${target_uid}:${target_gid} /repair/data /repair/custom /repair/logs && chmod -R u+rwX,g+rwX,o-rwx /repair/data /repair/custom /repair/logs" \
    || die "failed to repair legacy n8n ownership; repair only data/custom/logs under '${n8n_root}'"

  log "repaired legacy n8n ownership with containerized chown (uid=${target_uid} gid=${target_gid})"
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

upsert_key_value_in_file() {
  local file_path="$1"
  local key="$2"
  local value="$3"
  local tmp_file

  [[ -f "${file_path}" ]] || return 1
  tmp_file="$(mktemp "${file_path}.tmp.XXXXXX")" || return 1

  awk -v k="${key}" -v v="${value}" '
    BEGIN { replaced=0 }
    $0 ~ ("^" k "=") {
      if (!replaced) {
        print k "=" v
        replaced=1
      }
      next
    }
    { print }
    END {
      if (!replaced) {
        print k "=" v
      }
    }
  ' "${file_path}" >"${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }

  chmod 0640 "${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }
  mv "${tmp_file}" "${file_path}" || {
    rm -f "${tmp_file}"
    return 1
  }
}

optional_request_default_need() {
  local module="$1"
  case "${module}" in
    mcp) printf '%s\n' "Expose a restricted MCP catalog for local automation workflows." ;;
    pi-mono) printf '%s\n' "Provide an additional isolated CLI agent runtime for targeted tasks." ;;
    goose) printf '%s\n' "Provide an isolated Goose CLI runtime for approved workflows." ;;
    portainer) printf '%s\n' "Provide temporary loopback-only Portainer visibility for local diagnostics." ;;
    n8n) printf '%s\n' "Provide workflow automation service for local agentic workflows." ;;
    n8n-ai) printf '%s\n' "Provide a fully local n8n AI Assistant with Ollama, Sysbox sandbox, and SearXNG." ;;
    *) return 1 ;;
  esac
}

optional_request_default_success() {
  local module="$1"
  case "${module}" in
    mcp) printf '%s\n' "Only allowlisted tools are available and service healthcheck stays green." ;;
    pi-mono) printf '%s\n' "Container starts with expected user/workspace mappings and no forbidden mounts." ;;
    goose) printf '%s\n' "Container starts successfully with isolated workspace and expected proxy controls." ;;
    portainer) printf '%s\n' "UI is reachable on loopback only and runs without docker.sock mount." ;;
    n8n) printf '%s\n' "n8n service and loopback proxy start successfully with healthchecks passing." ;;
    n8n-ai) printf '%s\n' "Local model, sandbox API/runner, and SearXNG start with healthchecks passing." ;;
    *) return 1 ;;
  esac
}

ensure_optional_request_file() {
  local module="$1"
  local request_file="${AGENTIC_ROOT}/deployments/optional/${module}.request"
  local need_value
  local success_value
  local owner_value

  need_value="$(optional_request_default_need "${module}")" \
    || die "unable to resolve default need for optional module '${module}'"
  success_value="$(optional_request_default_success "${module}")" \
    || die "unable to resolve default success for optional module '${module}'"
  owner_value="${SUDO_USER:-${USER:-operator}}"

  copy_if_missing "${TEMPLATE_DIR}/activation.request.example" "${request_file}" 0640

  if ! grep -Eq '^need=[^[:space:]].+$' "${request_file}"; then
    upsert_key_value_in_file "${request_file}" "need" "${need_value}" \
      || die "failed to update need= in ${request_file}"
  fi

  if ! grep -Eq '^success=[^[:space:]].+$' "${request_file}"; then
    upsert_key_value_in_file "${request_file}" "success" "${success_value}" \
      || die "failed to update success= in ${request_file}"
  fi

  if ! grep -Eq '^owner=' "${request_file}"; then
    upsert_key_value_in_file "${request_file}" "owner" "${owner_value}" \
      || die "failed to update owner= in ${request_file}"
  fi

  if ! grep -Eq '^expires_at=' "${request_file}"; then
    upsert_key_value_in_file "${request_file}" "expires_at" "" \
      || die "failed to update expires_at= in ${request_file}"
  fi
}

migrate_n8n_config_mountpoint() {
  local config_path="${AGENTIC_ROOT}/optional/n8n/data/config"
  local backup_path

  [[ -d "${config_path}" ]] || return 0

  backup_path="${config_path}.directory-backup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mv "${config_path}" "${backup_path}" \
    || die "failed to preserve legacy n8n config directory ${config_path}; fix its ownership and re-run runtime init"
  log "migrated legacy n8n config directory to recoverable backup: ${backup_path}"
}

main() {
  local runtime_uid="${AGENT_RUNTIME_UID:-1000}"
  local runtime_gid="${AGENT_RUNTIME_GID:-1000}"
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

  repair_rootless_n8n_layout

  install -d -m 0750 "${AGENTIC_ROOT}/optional"
  install -d -m 0750 "${AGENTIC_ROOT}/optional/mcp"
  install -d -m 0750 "${AGENTIC_ROOT}/optional/mcp/config"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/mcp/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/mcp/logs"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/pi-mono"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/pi-mono/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/pi-mono/logs"
  install -d -m 0770 "${AGENTIC_PI_MONO_WORKSPACES_DIR}"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/goose"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/goose/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/goose/logs"
  install -d -m 0770 "${AGENTIC_GOOSE_WORKSPACES_DIR}"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/git"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/git/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/git/config"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/git/bootstrap"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/portainer"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/portainer/data"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/portainer/logs"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/n8n"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/n8n/data"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/n8n/custom"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/n8n/logs"
  migrate_n8n_config_mountpoint

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  install -d -m 0750 "${AGENTIC_ROOT}/deployments/optional"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets"
  install -d -m 0750 "${AGENTIC_ROOT}/secrets/ssh"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets/ssh/pi-mono"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets/ssh/goose"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets/runtime"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox"
  install -d -m 0750 "${AGENTIC_ROOT}/secrets/runtime/git-forge"

  copy_if_missing "${TEMPLATE_DIR}/mcp.tool_allowlist.txt" "${AGENTIC_ROOT}/optional/mcp/config/tool_allowlist.txt" 0640
  ensure_optional_request_file "mcp"
  ensure_optional_request_file "pi-mono"
  ensure_optional_request_file "goose"
  ensure_optional_request_file "portainer"
  ensure_optional_request_file "n8n"
  ensure_optional_request_file "n8n-ai"

  chmod 0644 "${AGENTIC_ROOT}/optional/mcp/config/tool_allowlist.txt"

  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/mcp.token"
  ensure_secret_file_if_missing "${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/api.key"
  ensure_secret_file_if_missing "${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/registration.token"
  ensure_secret_file_if_missing "${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/runner.key"
  ensure_secret_file_if_missing "${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/searxng.key"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/api.key"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/registration.token"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/runner.key"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/searxng.key"
  for git_forge_secret in "${git_forge_accounts[@]}"; do
    ensure_secret_file_if_missing "${AGENTIC_ROOT}/secrets/runtime/git-forge/${git_forge_secret}.password"
    ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/git-forge/${git_forge_secret}.password"
    chmod 0640 "${AGENTIC_ROOT}/secrets/runtime/git-forge/${git_forge_secret}.password" || true
  done

  if [[ "${EUID}" -eq 0 ]]; then
    chown -R "${runtime_uid}:${runtime_gid}" \
      "${AGENTIC_ROOT}/optional/mcp/state" \
      "${AGENTIC_ROOT}/optional/mcp/logs" \
      "${AGENTIC_ROOT}/optional/git/state" \
      "${AGENTIC_ROOT}/optional/git/config" \
      "${AGENTIC_ROOT}/optional/git/bootstrap" \
      "${AGENTIC_ROOT}/optional/pi-mono/state" \
      "${AGENTIC_ROOT}/optional/pi-mono/logs" \
      "${AGENTIC_PI_MONO_WORKSPACES_DIR}" \
      "${AGENTIC_ROOT}/optional/goose/state" \
      "${AGENTIC_ROOT}/optional/goose/logs" \
      "${AGENTIC_GOOSE_WORKSPACES_DIR}" \
      "${AGENTIC_ROOT}/secrets/ssh/pi-mono" \
      "${AGENTIC_ROOT}/secrets/ssh/goose" \
      "${AGENTIC_ROOT}/optional/portainer/data" \
      "${AGENTIC_ROOT}/optional/portainer/logs" \
      "${AGENTIC_ROOT}/optional/n8n/data" \
      "${AGENTIC_ROOT}/optional/n8n/custom" \
      "${AGENTIC_ROOT}/optional/n8n/logs"
    if [[ -f "${AGENTIC_ROOT}/secrets/runtime/mcp.token" ]]; then
      chown "${runtime_uid}:${runtime_gid}" "${AGENTIC_ROOT}/secrets/runtime/mcp.token"
    fi
    for git_forge_secret in "${git_forge_accounts[@]}"; do
      if [[ -f "${AGENTIC_ROOT}/secrets/runtime/git-forge/${git_forge_secret}.password" ]]; then
        chown "${runtime_uid}:${runtime_gid}" "${AGENTIC_ROOT}/secrets/runtime/git-forge/${git_forge_secret}.password"
        chmod 0640 "${AGENTIC_ROOT}/secrets/runtime/git-forge/${git_forge_secret}.password" || true
      fi
    done
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    chmod 0770 "${AGENTIC_ROOT}/optional/mcp/state" \
      "${AGENTIC_ROOT}/optional/mcp/logs" \
      "${AGENTIC_ROOT}/optional/git/state" \
      "${AGENTIC_ROOT}/optional/git/config" \
      "${AGENTIC_ROOT}/optional/git/bootstrap" \
      "${AGENTIC_ROOT}/optional/pi-mono/state" \
      "${AGENTIC_ROOT}/optional/pi-mono/logs" \
      "${AGENTIC_PI_MONO_WORKSPACES_DIR}" \
      "${AGENTIC_ROOT}/optional/goose/state" \
      "${AGENTIC_ROOT}/optional/goose/logs" \
      "${AGENTIC_GOOSE_WORKSPACES_DIR}" \
      "${AGENTIC_ROOT}/secrets/ssh/pi-mono" \
      "${AGENTIC_ROOT}/secrets/ssh/goose" \
      "${AGENTIC_ROOT}/optional/portainer/data" \
      "${AGENTIC_ROOT}/optional/portainer/logs" \
      "${AGENTIC_ROOT}/optional/n8n/data" \
      "${AGENTIC_ROOT}/optional/n8n/custom" \
      "${AGENTIC_ROOT}/optional/n8n/logs"
    log "non-root runtime init: relaxed optional dirs permissions for userns compatibility"
  fi
}

main "$@"
