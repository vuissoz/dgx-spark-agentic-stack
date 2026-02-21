#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/../../scripts/lib/runtime.sh"

AGENTIC_HOST_NET_BACKUPS_DIR="${AGENTIC_HOST_NET_BACKUPS_DIR:-${AGENTIC_ROOT}/deployments/host-net/backups}"

log() {
  echo "INFO: $*" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_net_admin_access() {
  if [[ "${EUID}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${AGENTIC_ALLOW_NON_ROOT_NET_ADMIN:-0}" != "1" ]]; then
    die "rollback_docker_user.sh requires root privileges (run with sudo), or set AGENTIC_ALLOW_NON_ROOT_NET_ADMIN=1 with an iptables helper in PATH"
  fi

  if ! iptables -S >/dev/null 2>&1; then
    die "non-root net-admin mode requested but iptables access probe failed; ensure PATH helper can access host netfilter tables"
  fi

  log "non-root net-admin mode enabled (AGENTIC_ALLOW_NON_ROOT_NET_ADMIN=1)"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

record_change() {
  local backup_id="$1"
  local actor="${SUDO_USER:-${USER:-unknown}}"
  local changes_log="${AGENTIC_ROOT}/deployments/changes.log"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${changes_log}"
  chmod 0640 "${changes_log}" || true

  printf '%s action=host-net-rollback backup_id=%s actor=%s chain=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${backup_id}" "${actor}" "${AGENTIC_DOCKER_USER_CHAIN}" \
    >>"${changes_log}"
}

usage() {
  cat <<USAGE
Usage:
  rollback_docker_user.sh <backup_id>
USAGE
}

snapshot_has_chain_definition() {
  local snapshot_file="$1"
  local chain="$2"

  awk -v chain="${chain}" '
    $0 == "*filter" {in_filter=1; next}
    in_filter && $0 == "COMMIT" {in_filter=0}
    in_filter && $0 ~ "^:" chain " " {found=1}
    END {exit(found ? 0 : 1)}
  ' "${snapshot_file}"
}

restore_chain_rules_from_snapshot() {
  local snapshot_file="$1"
  local chain="$2"

  awk -v chain="${chain}" '
    $0 == "*filter" {in_filter=1; next}
    in_filter && $0 == "COMMIT" {in_filter=0}
    in_filter && $1 == "-A" && $2 == chain {print}
  ' "${snapshot_file}" | while IFS= read -r rule; do
    [[ -n "${rule}" ]] || continue
    # Rules come from iptables-save snapshot captured on the same host.
    # shellcheck disable=SC2016
    eval "iptables ${rule}"
  done
}

remove_jump_to_chain() {
  local chain="$1"

  while iptables -C DOCKER-USER -j "${chain}" 2>/dev/null; do
    iptables -D DOCKER-USER -j "${chain}"
  done
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

  require_cmd iptables
  require_cmd awk
  require_net_admin_access

  local backup_dir="${AGENTIC_HOST_NET_BACKUPS_DIR}/${backup_id}"
  local snapshot_file="${backup_dir}/iptables-save.rules"
  [[ -d "${backup_dir}" ]] || die "backup not found: ${backup_dir}"
  [[ -f "${snapshot_file}" ]] || die "missing snapshot file: ${snapshot_file}"

  iptables -N DOCKER-USER 2>/dev/null || true
  remove_jump_to_chain "${AGENTIC_DOCKER_USER_CHAIN}"

  if iptables -S "${AGENTIC_DOCKER_USER_CHAIN}" >/dev/null 2>&1; then
    iptables -F "${AGENTIC_DOCKER_USER_CHAIN}"
    iptables -X "${AGENTIC_DOCKER_USER_CHAIN}" 2>/dev/null || true
  fi

  iptables -F DOCKER-USER

  if snapshot_has_chain_definition "${snapshot_file}" "${AGENTIC_DOCKER_USER_CHAIN}"; then
    iptables -N "${AGENTIC_DOCKER_USER_CHAIN}"
  fi

  restore_chain_rules_from_snapshot "${snapshot_file}" "DOCKER-USER"
  if snapshot_has_chain_definition "${snapshot_file}" "${AGENTIC_DOCKER_USER_CHAIN}"; then
    restore_chain_rules_from_snapshot "${snapshot_file}" "${AGENTIC_DOCKER_USER_CHAIN}"
  fi

  record_change "${backup_id}"
  printf 'rollback completed backup_id=%s\n' "${backup_id}"
}

main "$@"
