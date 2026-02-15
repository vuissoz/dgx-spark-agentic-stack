#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
TEMPLATE_DIR="${REPO_ROOT}/examples/obs"

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

main() {
  install -d -m 0750 "${AGENTIC_ROOT}/monitoring"
  install -d -m 0750 "${AGENTIC_ROOT}/monitoring/config"
  install -d -m 0770 "${AGENTIC_ROOT}/monitoring/prometheus"
  install -d -m 0770 "${AGENTIC_ROOT}/monitoring/grafana"
  install -d -m 0770 "${AGENTIC_ROOT}/monitoring/loki"
  install -d -m 0770 "${AGENTIC_ROOT}/monitoring/promtail"
  install -d -m 0770 "${AGENTIC_ROOT}/monitoring/promtail/positions"

  copy_if_missing "${TEMPLATE_DIR}/prometheus.yml" "${AGENTIC_ROOT}/monitoring/config/prometheus.yml" 0644
  copy_if_missing "${TEMPLATE_DIR}/loki-config.yml" "${AGENTIC_ROOT}/monitoring/config/loki-config.yml" 0644
  copy_if_missing "${TEMPLATE_DIR}/promtail-config.yml" "${AGENTIC_ROOT}/monitoring/config/promtail-config.yml" 0644

  if [[ "${EUID}" -eq 0 ]]; then
    # Grafana official container runs as uid 472.
    chown -R 472:472 "${AGENTIC_ROOT}/monitoring/grafana"
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    chmod 0777 "${AGENTIC_ROOT}/monitoring/prometheus" \
      "${AGENTIC_ROOT}/monitoring/grafana" \
      "${AGENTIC_ROOT}/monitoring/loki" \
      "${AGENTIC_ROOT}/monitoring/promtail" \
      "${AGENTIC_ROOT}/monitoring/promtail/positions"
    log "non-root runtime init: relaxed monitoring dirs permissions for userns compatibility"
  fi
}

main "$@"
