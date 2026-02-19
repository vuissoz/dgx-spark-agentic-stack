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

append_unique() {
  local -n array_ref="$1"
  local value="$2"
  local existing

  for existing in "${array_ref[@]:-}"; do
    if [[ "${existing}" == "${value}" ]]; then
      return 0
    fi
  done

  array_ref+=("${value}")
}

collect_service_ips() {
  local service="$1"
  local -n ips_ref="$2"
  shift 2
  local -a networks=("$@")
  local container_id network_name ip

  container_id="$(service_container_id "${service}")"
  if [[ -z "${container_id}" ]]; then
    return 1
  fi

  for network_name in "${networks[@]}"; do
    ip="$(container_ip_on_network "${container_id}" "${network_name}")"
    [[ -n "${ip}" ]] || continue
    append_unique ips_ref "${ip}"
  done

  [[ "${#ips_ref[@]}" -gt 0 ]]
}

main() {
  require_root
  require_cmd docker
  require_cmd iptables
  require_cmd iptables-save

  local network_name
  local subnet
  local src_subnet
  local proxy_ip
  local unbound_ip
  local gate_ip
  local backup_id
  local -a source_networks=()
  local -a source_subnets=()
  local -a proxy_ips=()
  local -a unbound_ips=()
  local -a gate_ips=()
  declare -A seen_networks=()

  for network_name in "${AGENTIC_NETWORK}" "${AGENTIC_EGRESS_NETWORK}"; do
    [[ -n "${network_name}" ]] || continue
    if [[ -n "${seen_networks[${network_name}]:-}" ]]; then
      continue
    fi
    seen_networks["${network_name}"]=1
    source_networks+=("${network_name}")

    subnet="$(docker network inspect "${network_name}" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
    [[ -n "${subnet}" ]] || die "docker network '${network_name}' not found; run 'agent up core' first"
    append_unique source_subnets "${subnet}"
  done

  collect_service_ips "${AGENTIC_PROXY_SERVICE}" proxy_ips "${source_networks[@]}" \
    || die "cannot resolve IPs for '${AGENTIC_PROXY_SERVICE}' on ${source_networks[*]}"
  collect_service_ips "${AGENTIC_UNBOUND_SERVICE}" unbound_ips "${source_networks[@]}" \
    || die "cannot resolve IPs for '${AGENTIC_UNBOUND_SERVICE}' on ${source_networks[*]}"
  collect_service_ips "${AGENTIC_GATE_SERVICE}" gate_ips "${source_networks[@]}" || true

  backup_id="$(create_host_net_backup)"

  iptables -N DOCKER-USER 2>/dev/null || true
  iptables -N "${AGENTIC_DOCKER_USER_CHAIN}" 2>/dev/null || true
  iptables -F "${AGENTIC_DOCKER_USER_CHAIN}"

  iptables -C DOCKER-USER -j "${AGENTIC_DOCKER_USER_CHAIN}" 2>/dev/null \
    || iptables -I DOCKER-USER 1 -j "${AGENTIC_DOCKER_USER_CHAIN}"

  iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  for src_subnet in "${source_subnets[@]}"; do
    for unbound_ip in "${unbound_ips[@]}"; do
      iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" \
        -s "${src_subnet}" -d "${unbound_ip}/32" -p udp --dport "${AGENTIC_UNBOUND_PORT}" -j ACCEPT
      iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" \
        -s "${src_subnet}" -d "${unbound_ip}/32" -p tcp --dport "${AGENTIC_UNBOUND_PORT}" -j ACCEPT
    done

    for proxy_ip in "${proxy_ips[@]}"; do
      iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" \
        -s "${src_subnet}" -d "${proxy_ip}/32" -p tcp --dport "${AGENTIC_PROXY_PORT}" -j ACCEPT
    done

    for gate_ip in "${gate_ips[@]}"; do
      iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" \
        -s "${src_subnet}" -d "${gate_ip}/32" -p tcp --dport "${AGENTIC_GATE_PORT}" -j ACCEPT
      log "allowed LLM gate traffic to ${AGENTIC_GATE_SERVICE} (${gate_ip}:${AGENTIC_GATE_PORT})"
    done

    iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" \
      -s "${src_subnet}" \
      -m limit --limit 6/min --limit-burst 20 \
      -j LOG --log-prefix "${AGENTIC_DOCKER_USER_LOG_PREFIX}" --log-level 4

    iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" -s "${src_subnet}" -j DROP
  done
  iptables -A "${AGENTIC_DOCKER_USER_CHAIN}" -j RETURN

  if [[ "${backup_id}" != "skipped" ]]; then
    record_change "host-net-apply" "${backup_id}"
    printf 'backup_id=%s\n' "${backup_id}"
  fi

  log "applied DOCKER-USER enforcement for subnets ${source_subnets[*]}"
}

main "$@"
