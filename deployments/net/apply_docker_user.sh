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

log() {
  echo "INFO: $*"
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

  local subnet
  local proxy_container_id
  local unbound_container_id
  local proxy_ip
  local unbound_ip

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

  log "applied DOCKER-USER enforcement for subnet ${subnet}"
}

main "$@"
