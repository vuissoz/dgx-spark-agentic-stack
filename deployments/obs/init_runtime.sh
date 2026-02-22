#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
TEMPLATE_DIR="${REPO_ROOT}/examples/obs"
AGENTIC_PROFILE="${AGENTIC_PROFILE:-strict-prod}"
AGENT_RUNTIME_UID="${AGENT_RUNTIME_UID:-1000}"
AGENT_RUNTIME_GID="${AGENT_RUNTIME_GID:-1000}"

log() {
  echo "INFO: $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

repair_rootless_obs_layout() {
  local monitoring_root="${AGENTIC_ROOT}/monitoring"
  local first_unwritable=""
  local target_uid="${AGENT_RUNTIME_UID:-$(id -u)}"
  local target_gid="${AGENT_RUNTIME_GID:-$(id -g)}"

  [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]] || return 0
  [[ "${EUID}" -ne 0 ]] || return 0
  [[ -d "${monitoring_root}" ]] || return 0

  if [[ ! -w "${monitoring_root}" ]] || [[ ! -x "${monitoring_root}" ]]; then
    first_unwritable="${monitoring_root}"
  else
    first_unwritable="$(find "${monitoring_root}" -mindepth 0 ! -writable -print -quit 2>/dev/null || true)"
  fi
  [[ -n "${first_unwritable}" ]] || return 0

  command -v docker >/dev/null 2>&1 \
    || die "docker command is required to repair legacy monitoring ownership in rootless-dev (first unwritable path: ${first_unwritable})"

  if ! docker run --rm \
    -v "${monitoring_root}:/repair/monitoring" \
    busybox:1.36.1 sh -lc \
    "chown -R ${target_uid}:${target_gid} /repair/monitoring && chmod -R u+rwX,g+rwX,o-rwx /repair/monitoring"; then
    die "failed to repair monitoring ownership for rootless-dev runtime (first unwritable path: ${first_unwritable}); run: sudo chown -R ${target_uid}:${target_gid} '${monitoring_root}' && sudo chmod -R u+rwX,g+rwX,o-rwx '${monitoring_root}'"
  fi

  log "repaired legacy monitoring ownership with containerized chown (uid=${target_uid} gid=${target_gid})"
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

promtail_path_migration() {
  local cfg="${AGENTIC_ROOT}/monitoring/config/promtail-config.yml"
  [[ -f "${cfg}" ]] || return 0

  # Rootless runtimes keep proxy logs under AGENTIC_ROOT; mount to /tmp to stay compatible with read_only rootfs.
  if grep -q '/var/log/agentic-proxy/access.log\*' "${cfg}"; then
    sed -i 's#/var/log/agentic-proxy/access.log\*#/tmp/agentic-proxy/access.log*#g' "${cfg}"
    log "migrated promtail proxy log path to /tmp/agentic-proxy in ${cfg}"
  fi
}

main() {
  repair_rootless_obs_layout

  install -d -m 0750 "${AGENTIC_ROOT}/monitoring"
  install -d -m 0750 "${AGENTIC_ROOT}/monitoring/config"
  install -d -m 0770 "${AGENTIC_ROOT}/monitoring/prometheus"
  install -d -m 0770 "${AGENTIC_ROOT}/monitoring/grafana"
  install -d -m 0770 "${AGENTIC_ROOT}/monitoring/loki"
  install -d -m 0770 "${AGENTIC_ROOT}/monitoring/promtail"
  install -d -m 0770 "${AGENTIC_ROOT}/monitoring/promtail/positions"

  copy_if_missing "${TEMPLATE_DIR}/prometheus.yml" "${AGENTIC_ROOT}/monitoring/config/prometheus.yml" 0644
  copy_if_missing "${TEMPLATE_DIR}/prometheus-alerts.yml" "${AGENTIC_ROOT}/monitoring/config/prometheus-alerts.yml" 0644
  copy_if_missing "${TEMPLATE_DIR}/loki-config.yml" "${AGENTIC_ROOT}/monitoring/config/loki-config.yml" 0644
  copy_if_missing "${TEMPLATE_DIR}/promtail-config.yml" "${AGENTIC_ROOT}/monitoring/config/promtail-config.yml" 0644
  promtail_path_migration

  if [[ "${EUID}" -eq 0 ]]; then
    # Grafana official container runs as uid 472.
    chown -R 472:472 "${AGENTIC_ROOT}/monitoring/grafana"
    chown -R "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" \
      "${AGENTIC_ROOT}/monitoring/prometheus" \
      "${AGENTIC_ROOT}/monitoring/loki"
  fi

  if [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]] && [[ "${EUID}" -ne 0 ]]; then
    chmod 0770 "${AGENTIC_ROOT}/monitoring/prometheus" \
      "${AGENTIC_ROOT}/monitoring/grafana" \
      "${AGENTIC_ROOT}/monitoring/loki" \
      "${AGENTIC_ROOT}/monitoring/promtail" \
      "${AGENTIC_ROOT}/monitoring/promtail/positions"
    log "rootless runtime init: relaxed monitoring dirs permissions for userns compatibility"
  fi
}

main "$@"
