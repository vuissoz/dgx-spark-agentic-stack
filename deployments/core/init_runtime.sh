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

  chmod 0755 "${proxy_logs_dir}"

  if [[ "${EUID}" -ne 0 ]]; then
    log "non-root runtime init: keep current owner on ${proxy_logs_dir}"
    return 0
  fi

  chown 13:13 "${proxy_logs_dir}"
}

main() {
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
  set_proxy_runtime_permissions
}

main "$@"
