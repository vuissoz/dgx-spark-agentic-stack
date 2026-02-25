#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

runtime_env_file="${AGENTIC_ROOT}/deployments/runtime.env"
link_path="${AGENTIC_OLLAMA_MODELS_LINK:-${AGENTIC_REPO_ROOT}/.runtime/ollama-models}"
default_target_dir="${AGENTIC_REPO_ROOT}/.runtime/ollama-models-data"
target_dir="${AGENTIC_OLLAMA_MODELS_TARGET_DIR:-}"
link_backups_dir="${AGENTIC_OLLAMA_LINK_BACKUPS_DIR:-${AGENTIC_ROOT}/deployments/ollama-link/backups}"
changes_log="${AGENTIC_ROOT}/deployments/changes.log"
skip_backup="${AGENTIC_SKIP_OLLAMA_LINK_BACKUP:-0}"
force=0
quiet=0

usage() {
  cat <<USAGE
Usage:
  setup-ollama-models-link.sh [--force] [--quiet] [--link-path <path>] [--target-dir <path>]

Defaults:
  --link-path  ${link_path}
  --target-dir ${target_dir:-<derived from OLLAMA_MODELS_DIR or ${default_target_dir}>}
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  if [[ "${quiet}" -eq 0 ]]; then
    echo "INFO: $*"
  fi
}

runtime_env_value() {
  local key="$1"
  if [[ ! -f "${runtime_env_file}" ]]; then
    printf '%s\n' ""
    return 0
  fi

  sed -n "s/^${key}=//p" "${runtime_env_file}" | tail -n 1
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

record_change() {
  local action="$1"
  local backup_id="$2"
  local actor="${SUDO_USER:-${USER:-unknown}}"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${changes_log}"
  chmod 0640 "${changes_log}" || true

  printf '%s action=%s backup_id=%s actor=%s link=%s target=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${action}" "${backup_id}" "${actor}" "${link_path}" "${target_dir}" \
    >>"${changes_log}"
}

next_backup_id() {
  local base id suffix
  base="$(date -u +%Y%m%dT%H%M%SZ)"
  id="${base}"
  suffix=0

  while [[ -e "${link_backups_dir}/${id}" ]]; do
    suffix=$((suffix + 1))
    id="${base}-${suffix}"
  done

  printf '%s\n' "${id}"
}

create_backup() {
  local backup_id backup_dir latest_link
  local link_state link_target

  if [[ "${skip_backup}" == "1" ]]; then
    log "ollama-link backup disabled by AGENTIC_SKIP_OLLAMA_LINK_BACKUP=1"
    printf '%s\n' "skipped"
    return 0
  fi

  install -d -m 0750 "${AGENTIC_ROOT}/deployments/ollama-link"
  install -d -m 0750 "${link_backups_dir}"

  backup_id="$(next_backup_id)"
  backup_dir="${link_backups_dir}/${backup_id}"
  latest_link="${AGENTIC_ROOT}/deployments/ollama-link/latest"
  install -d -m 0750 "${backup_dir}"

  if [[ -L "${link_path}" ]]; then
    link_state="symlink"
    link_target="$(readlink "${link_path}")"
  else
    link_state="missing"
    link_target=""
  fi

  {
    printf 'backup_id=%s\n' "${backup_id}"
    printf 'created_at_utc=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf 'actor=%s\n' "${SUDO_USER:-${USER:-unknown}}"
    printf 'profile=%s\n' "${AGENTIC_PROFILE}"
    printf 'link_path=%s\n' "${link_path}"
    printf 'requested_target_dir=%s\n' "${target_dir}"
    printf 'link_state=%s\n' "${link_state}"
    printf 'link_target=%s\n' "${link_target}"
    printf 'runtime_OLLAMA_MODELS_DIR=%s\n' "$(runtime_env_value OLLAMA_MODELS_DIR)"
    printf 'runtime_AGENTIC_OLLAMA_MODELS_LINK=%s\n' "$(runtime_env_value AGENTIC_OLLAMA_MODELS_LINK)"
    printf 'runtime_AGENTIC_OLLAMA_MODELS_TARGET_DIR=%s\n' "$(runtime_env_value AGENTIC_OLLAMA_MODELS_TARGET_DIR)"
  } >"${backup_dir}/backup.env"
  chmod 0640 "${backup_dir}/backup.env" || true

  ln -sfn "${backup_dir}" "${latest_link}"
  record_change "ollama-link-backup" "${backup_id}"

  log "created ollama-link backup id=${backup_id} path=${backup_dir}"
  printf '%s\n' "${backup_id}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        force=1
        shift
        ;;
      --quiet)
        quiet=1
        shift
        ;;
      --link-path)
        [[ $# -ge 2 ]] || die "--link-path requires a value"
        link_path="$2"
        shift 2
        ;;
      --target-dir)
        [[ $# -ge 2 ]] || die "--target-dir requires a value"
        target_dir="$2"
        shift 2
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  local needs_change=0
  local replace_existing=0
  local backup_id="none"
  local env_ollama_models_dir="${OLLAMA_MODELS_DIR:-}"

  if [[ "${AGENTIC_PROFILE}" != "rootless-dev" ]]; then
    die "setup-ollama-models-link.sh is intended for AGENTIC_PROFILE=rootless-dev"
  fi

  if [[ -z "${target_dir}" ]]; then
    if [[ -n "${env_ollama_models_dir}" && "${env_ollama_models_dir}" != "${link_path}" ]]; then
      target_dir="${env_ollama_models_dir}"
    else
      target_dir="${default_target_dir}"
    fi
  fi

  install -d -m 0770 "$(dirname "${target_dir}")"
  install -d -m 0770 "${target_dir}"

  install -d -m 0770 "$(dirname "${link_path}")"
  if [[ -e "${link_path}" || -L "${link_path}" ]]; then
    if [[ -L "${link_path}" ]]; then
      current_target="$(readlink "${link_path}")"
      if [[ "${current_target}" != "${target_dir}" ]]; then
        if [[ "${force}" -eq 1 ]]; then
          needs_change=1
          replace_existing=1
        else
          die "link already exists with another target (${link_path} -> ${current_target}); use --force to replace"
        fi
      fi
    else
      die "path exists and is not a symlink: ${link_path}"
    fi
  else
    needs_change=1
  fi

  if [[ "${needs_change}" -eq 1 ]]; then
    backup_id="$(create_backup)"
    if [[ "${replace_existing}" -eq 1 && -L "${link_path}" ]]; then
      rm -f "${link_path}"
    fi
  fi

  if [[ ! -L "${link_path}" ]]; then
    ln -s "${target_dir}" "${link_path}"
    log "created symlink ${link_path} -> ${target_dir}"
  else
    log "symlink already in place: ${link_path} -> ${target_dir}"
  fi

  set_runtime_env_value "OLLAMA_MODELS_DIR" "${link_path}"
  set_runtime_env_value "AGENTIC_OLLAMA_MODELS_LINK" "${link_path}"
  set_runtime_env_value "AGENTIC_OLLAMA_MODELS_TARGET_DIR" "${target_dir}"
  if [[ "${backup_id}" != "none" && "${backup_id}" != "skipped" ]]; then
    record_change "ollama-link-apply" "${backup_id}"
  fi

  printf 'OLLAMA_MODELS_DIR=%s\n' "${link_path}"
  printf 'backup_id=%s\n' "${backup_id}"
}

main "$@"
