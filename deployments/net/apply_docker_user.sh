#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/../../scripts/lib/runtime.sh"

AGENTIC_PROXY_SERVICE="${AGENTIC_PROXY_SERVICE:-egress-proxy}"
AGENTIC_UNBOUND_SERVICE="${AGENTIC_UNBOUND_SERVICE:-unbound}"
AGENTIC_PROXY_PORT="${AGENTIC_PROXY_PORT:-3128}"
AGENTIC_UNBOUND_PORT="${AGENTIC_UNBOUND_PORT:-53}"
AGENTIC_GATE_SERVICE="${AGENTIC_GATE_SERVICE:-ollama-gate}"
AGENTIC_GATE_PORT="${AGENTIC_GATE_PORT:-11435}"
AGENTIC_DOCKER_USER_LOG_PREFIX="${AGENTIC_DOCKER_USER_LOG_PREFIX:-AGENTIC-DROP }"
AGENTIC_HOST_NET_BACKUPS_DIR="${AGENTIC_HOST_NET_BACKUPS_DIR:-${AGENTIC_ROOT}/deployments/host-net/backups}"
AGENTIC_SKIP_HOST_NET_BACKUP="${AGENTIC_SKIP_HOST_NET_BACKUP:-0}"

log() {
  echo "INFO: $*" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "apply_docker_user.sh requires root privileges (run with sudo)"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

record_change() {
  local action="$1"
  local backup_id="$2"
  local actor="${SUDO_USER:-${USER:-unknown}}"
  local changes_log="${AGENTIC_ROOT}/deployments/changes.log"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${changes_log}"
  chmod 0640 "${changes_log}" || true

  printf '%s action=%s backup_id=%s actor=%s chain=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${action}" "${backup_id}" "${actor}" "${AGENTIC_DOCKER_USER_CHAIN}" \
    >>"${changes_log}"
}

next_backup_id() {
  local base id suffix
  base="$(date -u +%Y%m%dT%H%M%SZ)"
  id="${base}"
  suffix=0

  while [[ -e "${AGENTIC_HOST_NET_BACKUPS_DIR}/${id}" ]]; do
    suffix=$((suffix + 1))
    id="${base}-${suffix}"
  done

  printf '%s\n' "${id}"
}

create_host_net_backup() {
  local backup_id backup_dir latest_link

  if [[ "${AGENTIC_SKIP_HOST_NET_BACKUP}" == "1" ]]; then
    log "host-net backup disabled by AGENTIC_SKIP_HOST_NET_BACKUP=1"
    printf '%s\n' "skipped"
    return 0
  fi

  install -d -m 0750 "${AGENTIC_ROOT}/deployments/host-net"
  install -d -m 0750 "${AGENTIC_HOST_NET_BACKUPS_DIR}"

  backup_id="$(next_backup_id)"
  backup_dir="${AGENTIC_HOST_NET_BACKUPS_DIR}/${backup_id}"
  latest_link="${AGENTIC_ROOT}/deployments/host-net/latest"
  install -d -m 0750 "${backup_dir}"

  iptables-save >"${backup_dir}/iptables-save.rules"
  chmod 0640 "${backup_dir}/iptables-save.rules" || true

  {
    printf 'backup_id=%s\n' "${backup_id}"
    printf 'created_at_utc=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf 'profile=%s\n' "${AGENTIC_PROFILE}"
    printf 'compose_project=%s\n' "${AGENTIC_COMPOSE_PROJECT}"
    printf 'docker_user_chain=%s\n' "${AGENTIC_DOCKER_USER_CHAIN}"
    printf 'actor=%s\n' "${SUDO_USER:-${USER:-unknown}}"
  } >"${backup_dir}/backup.meta"
  chmod 0640 "${backup_dir}/backup.meta" || true

  ln -sfn "${backup_dir}" "${latest_link}"
  record_change "host-net-backup" "${backup_id}"

  log "created host-net backup id=${backup_id} path=${backup_dir}"
  printf '%s\n' "${backup_id}"
}

service_container_id() {
  local service="$1"
  docker ps \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}' | head -n 1
}

container_ip_on_network() {
  local container_id="$1"
  local network_name="$2"

  docker inspect --format "{{with index .NetworkSettings.Networks \"${network_name}\"}}{{.IPAddress}}{{end}}" "${container_id}"
}

allow_gate_if_present() {
  local source_subnet="$1"

  local gate_container_id
  local gate_ip

  gate_container_id="$(service_container_id "${AGENTIC_GATE_SERVICE}")"
  if [[ -z "${gate_container_id}" ]]; then
    return 0
  fi

  gate_ip="$(container_ip_on_network "${gate_container_id}" "${AGENTIC_NETWORK}")"
  if [[ -z "${gate_ip}" ]]; then
    return 0
  fi

  iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" \
    -s "${source_subnet}" \
    -d "${gate_ip}/32" \
    -p tcp --dport "${AGENTIC_GATE_PORT}" -j ACCEPT
  log "allowed LLM gate traffic to ${AGENTIC_GATE_SERVICE} (${gate_ip}:${AGENTIC_GATE_PORT})"
}

main() {
  require_root
  require_cmd docker
  require_cmd iptables
  require_cmd iptables-save

  local subnet
  local proxy_container_id
  local unbound_container_id
  local proxy_ip
  local unbound_ip
  local backup_id

  subnet="$(docker network inspect "${AGENTIC_NETWORK}" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
  [[ -n "${subnet}" ]] || die "docker network '${AGENTIC_NETWORK}' not found; run 'agent up core' first"

  proxy_container_id="$(service_container_id "${AGENTIC_PROXY_SERVICE}")"
  unbound_container_id="$(service_container_id "${AGENTIC_UNBOUND_SERVICE}")"
  [[ -n "${proxy_container_id}" ]] || die "service '${AGENTIC_PROXY_SERVICE}' is not running"
  [[ -n "${unbound_container_id}" ]] || die "service '${AGENTIC_UNBOUND_SERVICE}' is not running"

  proxy_ip="$(container_ip_on_network "${proxy_container_id}" "${AGENTIC_NETWORK}")"
  unbound_ip="$(container_ip_on_network "${unbound_container_id}" "${AGENTIC_NETWORK}")"
  [[ -n "${proxy_ip}" ]] || die "cannot resolve IP for '${AGENTIC_PROXY_SERVICE}' on network '${AGENTIC_NETWORK}'"
  [[ -n "${unbound_ip}" ]] || die "cannot resolve IP for '${AGENTIC_UNBOUND_SERVICE}' on network '${AGENTIC_NETWORK}'"

  backup_id="$(create_host_net_backup)"

  iptables -N DOCKER-USER 2>/dev/null || true
  iptables -N "${AGENTIC_DOCKER_USER_CHAIN}" 2>/dev/null || true
  iptables -F "${AGENTIC_DOCKER_USER_CHAIN}"

  iptables -C DOCKER-USER -j "${AGENTIC_DOCKER_USER_CHAIN}" 2>/dev/null \
    || iptables -I DOCKER-USER 1 -j "${AGENTIC_DOCKER_USER_CHAIN}"

  iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" \
    -s "${subnet}" -d "${unbound_ip}/32" -p udp --dport "${AGENTIC_UNBOUND_PORT}" -j ACCEPT
  iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" \
    -s "${subnet}" -d "${unbound_ip}/32" -p tcp --dport "${AGENTIC_UNBOUND_PORT}" -j ACCEPT

  iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" \
    -s "${subnet}" -d "${proxy_ip}/32" -p tcp --dport "${AGENTIC_PROXY_PORT}" -j ACCEPT

  allow_gate_if_present "${subnet}"

  iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" \
    -s "${subnet}" \
    -m limit --limit 6/min --limit-burst 20 \
    -j LOG --log-prefix "${AGENTIC_DOCKER_USER_LOG_PREFIX}" --log-level 4

  iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" -s "${subnet}" -j DROP
  iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" -j RETURN

  if [[ "${backup_id}" != "skipped" ]]; then
    record_change "host-net-apply" "${backup_id}"
    printf 'backup_id=%s\n' "${backup_id}"
  fi

  log "applied DOCKER-USER enforcement for subnet ${subnet}"
}

main "$@"
