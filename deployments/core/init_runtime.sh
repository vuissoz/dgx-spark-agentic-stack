#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
TEMPLATE_DIR="${REPO_ROOT}/examples/core"

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

  [[ -f "$src" ]] || die "template not found: ${src}"
  if [[ -f "$dst" ]]; then
    log "preserve existing runtime file: ${dst}"
    return 0
  fi

  install -D -m "$mode" "$src" "$dst"
  log "created runtime file: ${dst}"
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
  local gate_state_dir="${AGENTIC_ROOT}/gate/state"
  local gate_logs_dir="${AGENTIC_ROOT}/gate/logs"

  if [[ "${EUID}" -eq 0 ]]; then
    chmod 0750 "${gate_dir}"
    chmod 0770 "${gate_state_dir}" "${gate_logs_dir}"
    return 0
  fi

  # Non-root local runs can include userns-remapped containers; relax only runtime test paths.
  chmod 0755 "${gate_dir}"
  chmod 0770 "${gate_state_dir}" "${gate_logs_dir}"
  log "non-root runtime init: relaxed gate dir permissions for userns compatibility"
}

main() {
  install -d -m 0750 "${AGENTIC_ROOT}/ollama"
  install -d -m 0770 "${AGENTIC_ROOT}/ollama/models"
  install -d -m 0750 "${AGENTIC_ROOT}/gate"
  install -d -m 0770 "${AGENTIC_ROOT}/gate/state"
  install -d -m 0770 "${AGENTIC_ROOT}/gate/logs"
  install -d -m 0750 "${AGENTIC_ROOT}/dns"
  install -d -m 0750 "${AGENTIC_ROOT}/proxy"
  install -d -m 0750 "${AGENTIC_ROOT}/proxy/config"
  install -d -m 0755 "${AGENTIC_ROOT}/proxy/logs"

  copy_if_missing "${TEMPLATE_DIR}/unbound.conf" "${AGENTIC_ROOT}/dns/unbound.conf" 0644
  copy_if_missing "${TEMPLATE_DIR}/squid.conf" "${AGENTIC_ROOT}/proxy/config/squid.conf" 0644
  copy_if_missing "${TEMPLATE_DIR}/allowlist.txt" "${AGENTIC_ROOT}/proxy/allowlist.txt" 0644
  chmod 0644 "${AGENTIC_ROOT}/dns/unbound.conf"
  chmod 0644 "${AGENTIC_ROOT}/proxy/config/squid.conf"
  chmod 0644 "${AGENTIC_ROOT}/proxy/allowlist.txt"
  set_gate_runtime_permissions
  set_proxy_runtime_permissions
}

main "$@"
