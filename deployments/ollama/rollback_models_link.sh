#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/../../scripts/lib/runtime.sh"

runtime_env_file="${AGENTIC_ROOT}/deployments/runtime.env"
link_backups_dir="${AGENTIC_OLLAMA_LINK_BACKUPS_DIR:-${AGENTIC_ROOT}/deployments/ollama-link/backups}"
changes_log="${AGENTIC_ROOT}/deployments/changes.log"

log() {
  echo "INFO: $*" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<USAGE
Usage:
  rollback_models_link.sh <backup_id|latest>
USAGE
}

backup_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "${file}" | tail -n 1
}

set_runtime_env_value() {
  local key="$1"
  local value="$2"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${runtime_env_file}"
  chmod 0640 "${runtime_env_file}" || true

  if grep -Eq "^${key}=" "${runtime_env_file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|g" "${runtime_env_file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${runtime_env_file}"
  fi
}

unset_runtime_env_value() {
  local key="$1"
  [[ -f "${runtime_env_file}" ]] || return 0
  sed -i "/^${key}=/d" "${runtime_env_file}"
}

restore_runtime_value() {
  local key="$1"
  local value="$2"

  if [[ -n "${value}" ]]; then
    set_runtime_env_value "${key}" "${value}"
  else
    unset_runtime_env_value "${key}"
  fi
}

record_change() {
  local backup_id="$1"
  local actor="${SUDO_USER:-${USER:-unknown}}"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${changes_log}"
  chmod 0640 "${changes_log}" || true

  printf '%s action=ollama-link-rollback backup_id=%s actor=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${backup_id}" "${actor}" \
    >>"${changes_log}"
}

main() {
  local backup_id="${1:-}"
  [[ -n "${backup_id}" ]] || {
    usage
    die "missing backup_id"
  }
  if [[ "${backup_id}" == "-h" || "${backup_id}" == "--help" || "${backup_id}" == "help" ]]; then
    usage
    exit 0
  fi

  local backup_dir
  if [[ "${backup_id}" == "latest" ]]; then
    backup_dir="$(readlink -f "${AGENTIC_ROOT}/deployments/ollama-link/latest" 2>/dev/null || true)"
    [[ -d "${backup_dir}" ]] || die "latest backup is not available under ${AGENTIC_ROOT}/deployments/ollama-link/latest"
    backup_id="$(basename "${backup_dir}")"
  else
    backup_dir="${link_backups_dir}/${backup_id}"
  fi
  local backup_file="${backup_dir}/backup.env"
  [[ -f "${backup_file}" ]] || die "backup file not found: ${backup_file}"

  local link_path link_state link_target
  link_path="$(backup_value "${backup_file}" "link_path")"
  link_state="$(backup_value "${backup_file}" "link_state")"
  link_target="$(backup_value "${backup_file}" "link_target")"

  [[ -n "${link_path}" ]] || die "backup is missing link_path: ${backup_file}"
  [[ "${link_state}" == "missing" || "${link_state}" == "symlink" ]] \
    || die "unsupported link_state='${link_state}' in backup: ${backup_file}"

  if [[ "${link_state}" == "missing" ]]; then
    if [[ -L "${link_path}" ]]; then
      rm -f "${link_path}"
      log "removed symlink ${link_path}"
    elif [[ -e "${link_path}" ]]; then
      die "cannot rollback: path exists and is not a symlink: ${link_path}"
    fi
  else
    [[ -n "${link_target}" ]] || die "backup link_state=symlink but link_target is empty"
    if [[ -L "${link_path}" ]]; then
      rm -f "${link_path}"
    elif [[ -e "${link_path}" ]]; then
      die "cannot rollback: path exists and is not a symlink: ${link_path}"
    fi
    install -d -m 0770 "$(dirname "${link_path}")"
    ln -s "${link_target}" "${link_path}"
    log "restored symlink ${link_path} -> ${link_target}"
  fi

  restore_runtime_value "OLLAMA_MODELS_DIR" "$(backup_value "${backup_file}" "runtime_OLLAMA_MODELS_DIR")"
  restore_runtime_value "AGENTIC_OLLAMA_MODELS_LINK" "$(backup_value "${backup_file}" "runtime_AGENTIC_OLLAMA_MODELS_LINK")"
  restore_runtime_value "AGENTIC_OLLAMA_MODELS_TARGET_DIR" "$(backup_value "${backup_file}" "runtime_AGENTIC_OLLAMA_MODELS_TARGET_DIR")"

  record_change "${backup_id}"
  printf 'rollback completed backup_id=%s\n' "${backup_id}"
}

main "$@"
