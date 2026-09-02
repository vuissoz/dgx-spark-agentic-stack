#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET_DIR="${SCRIPT_DIR}/n8n-sandbox"
VM_NAME="${AGENTIC_N8N_SANDBOX_VM_NAME:-agentic-n8n-sandbox}"
VM_CPUS="${AGENTIC_N8N_SANDBOX_VM_CPUS:-4}"
VM_MEMORY="${AGENTIC_N8N_SANDBOX_VM_MEMORY:-8G}"
VM_DISK="${AGENTIC_N8N_SANDBOX_VM_DISK:-60G}"
VM_IMAGE="${AGENTIC_N8N_SANDBOX_VM_IMAGE:-24.04}"
HOST_PROXY_PORT="${AGENTIC_PROXY_HOST_PORT:-3128}"
HOST_SSH_USER="${SUDO_USER:-${USER}}"
SANDBOX_PROXY_VIRTUAL_IP="${AGENTIC_N8N_SANDBOX_PROXY_VIRTUAL_IP:-192.0.2.1}"
AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
ACTION="${1:-status}"
shift || true

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*" >&2; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
vm_exists() { multipass info "${VM_NAME}" >/dev/null 2>&1; }
vm_state() { multipass info "${VM_NAME}" 2>/dev/null | awk '/^[[:space:]]*State:/ {print $2; exit}'; }
vm_ip() {
  multipass info "${VM_NAME}" --format json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)["info"]
entry = next(iter(data.values()))
for address in entry.get("ipv4", []):
    if not address.startswith("172."):
        print(address)
        break
' || true
}

vm_gateway() {
  multipass exec "${VM_NAME}" -- ip route show default 2>/dev/null \
    | awk '{print $3; exit}' || true
}

authorized_key_marker() {
  printf 'agentic-n8n-sandbox-vm:%s' "${VM_NAME}"
}

install_restricted_tunnel_key() {
  local public_key marker ssh_dir authorized_keys
  ssh_dir="${HOME}/.ssh"
  authorized_keys="${ssh_dir}/authorized_keys"
  marker="$(authorized_key_marker)"

  multipass exec "${VM_NAME}" -- sudo install -d -m 0700 /etc/n8n-sandbox
  multipass exec "${VM_NAME}" -- sudo sh -ec \
    'test -s /etc/n8n-sandbox/egress_tunnel_ed25519 || ssh-keygen -q -t ed25519 -N "" -C n8n-sandbox-egress -f /etc/n8n-sandbox/egress_tunnel_ed25519; chmod 0600 /etc/n8n-sandbox/egress_tunnel_ed25519; chmod 0644 /etc/n8n-sandbox/egress_tunnel_ed25519.pub'
  public_key="$(multipass exec "${VM_NAME}" -- sudo awk '{print $1, $2}' /etc/n8n-sandbox/egress_tunnel_ed25519.pub)"
  [[ "${public_key}" == ssh-ed25519\ * ]] || die "guest did not produce a valid Ed25519 tunnel key"

  install -d -m 0700 "${ssh_dir}"
  touch "${authorized_keys}"
  chmod 0600 "${authorized_keys}"
  if ! grep -Fq "${marker}" "${authorized_keys}"; then
    printf 'restrict,port-forwarding,permitopen="127.0.0.1:%s" %s %s\n' \
      "${HOST_PROXY_PORT}" "${public_key}" "${marker}" >>"${authorized_keys}"
  fi
}

remove_restricted_tunnel_key() {
  local marker authorized_keys filtered
  marker="$(authorized_key_marker)"
  authorized_keys="${HOME}/.ssh/authorized_keys"
  [[ -f "${authorized_keys}" ]] || return 0
  filtered="$(mktemp "${HOME}/.ssh/authorized_keys.XXXXXX")"
  chmod 0600 "${filtered}"
  grep -Fv "${marker}" "${authorized_keys}" >"${filtered}" || true
  mv "${filtered}" "${authorized_keys}"
}

usage() {
  cat <<'EOF'
Usage: manage_n8n_sandbox_vm.sh <create|start|stop|status|endpoint|destroy> [options]

Options for create:
  --name <name> --cpus <n> --memory <size> --disk <size> --image <release>
  --reuse-existing

Options for destroy:
  --yes
EOF
}

reuse_existing=0
confirmed=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) VM_NAME="${2:?missing value for --name}"; shift 2 ;;
    --cpus) VM_CPUS="${2:?missing value for --cpus}"; shift 2 ;;
    --memory) VM_MEMORY="${2:?missing value for --memory}"; shift 2 ;;
    --disk) VM_DISK="${2:?missing value for --disk}"; shift 2 ;;
    --image) VM_IMAGE="${2:?missing value for --image}"; shift 2 ;;
    --reuse-existing) reuse_existing=1; shift ;;
    --yes) confirmed=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd multipass
require_cmd python3

case "${ACTION}" in
  create)
    [[ "${VM_CPUS}" =~ ^[1-9][0-9]*$ ]] || die "cpus must be a positive integer"
    [[ "${VM_MEMORY}" =~ ^[1-9][0-9]*[MGT]$ ]] || die "invalid memory size: ${VM_MEMORY}"
    [[ "${VM_DISK}" =~ ^[1-9][0-9]*[MGT]$ ]] || die "invalid disk size: ${VM_DISK}"
    for required_file in compose.yml provision_guest.sh; do
      [[ -s "${ASSET_DIR}/${required_file}" ]] || die "missing VM asset: ${ASSET_DIR}/${required_file}"
    done
    secret_root="${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox"
    for secret_name in api.key registration.token runner.key; do
      [[ -s "${secret_root}/${secret_name}" ]] \
        || die "missing sandbox secret ${secret_root}/${secret_name}; run the optional runtime bootstrap first"
    done
    if vm_exists; then
      [[ "${reuse_existing}" == "1" ]] || die "VM '${VM_NAME}' already exists; use --reuse-existing"
      [[ "$(vm_state)" == "Running" ]] || multipass start "${VM_NAME}"
    else
      info "creating CPU-only VM ${VM_NAME} (${VM_CPUS} vCPU, ${VM_MEMORY} RAM, ${VM_DISK} sparse disk)"
      multipass launch "${VM_IMAGE}" --name "${VM_NAME}" --cpus "${VM_CPUS}" \
        --memory "${VM_MEMORY}" --disk "${VM_DISK}"
    fi
    multipass exec "${VM_NAME}" -- cloud-init status --wait >/dev/null
    resolved_ip="$(vm_ip)"
    [[ "${resolved_ip}" =~ ^10\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || die "VM must have a private Multipass IPv4 address (got: ${resolved_ip:-none})"
    host_gateway="$(vm_gateway)"
    [[ "${host_gateway}" =~ ^10\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || die "cannot resolve the private Multipass host gateway"
    [[ "${HOST_PROXY_PORT}" =~ ^[0-9]+$ ]] || die "invalid host proxy port: ${HOST_PROXY_PORT}"
    curl -fsS --max-time 10 --proxy "http://127.0.0.1:${HOST_PROXY_PORT}" \
      https://example.com >/dev/null \
      || die "monitored host egress proxy is unavailable on 127.0.0.1:${HOST_PROXY_PORT}; run ./agent up core"
    install_restricted_tunnel_key
    transfer_dir="${AGENTIC_N8N_SANDBOX_TRANSFER_DIR:-${HOME}}"
    [[ -d "${transfer_dir}" && -w "${transfer_dir}" ]] \
      || die "Multipass transfer directory must be writable: ${transfer_dir}"
    temp_env="$(mktemp "${transfer_dir}/n8n-sandbox-env.XXXXXX")"
    trap 'rm -f "${temp_env:-}"' EXIT
    chmod 0600 "${temp_env}"
    {
      printf 'SANDBOX_VM_BIND_IP=%s\n' "${resolved_ip}"
      printf 'SANDBOX_EGRESS_PROXY_URL=http://%s:3128\n' "${SANDBOX_PROXY_VIRTUAL_IP}"
      printf 'SANDBOX_API_KEYS=%s\n' "$(<"${secret_root}/api.key")"
      printf 'SANDBOX_API_RUNNER_REGISTRATION_TOKEN=%s\n' "$(<"${secret_root}/registration.token")"
      printf 'SANDBOX_API_RUNNER_API_KEY=%s\n' "$(<"${secret_root}/runner.key")"
      printf 'SANDBOX_API_DEFAULT_MAX_SANDBOXES=%s\n' "${N8N_SANDBOX_MAX_SANDBOXES:-4}"
      printf 'SANDBOX_RUNNER_API_KEYS=%s\n' "$(<"${secret_root}/runner.key")"
      printf 'SANDBOX_RUNNER_REGISTRATION_TOKEN=%s\n' "$(<"${secret_root}/registration.token")"
      printf 'SANDBOX_RUNNER_ID=runner-1\n'
      printf 'SANDBOX_RUNNER_CAPACITY_TOTAL=%s\n' "${N8N_SANDBOX_MAX_SANDBOXES:-4}"
      printf 'SANDBOX_RUNNER_IDLE_TTL_SECONDS=%s\n' "${N8N_SANDBOX_IDLE_TTL_SECONDS:-900}"
      printf 'SANDBOX_RUNNER_INTER_SANDBOX_NETWORK_ENABLED=false\n'
      printf 'SANDBOX_RUNNER_DEFAULT_MEMORY_MB=%s\n' "${N8N_SANDBOX_MEMORY_MB:-1024}"
      printf 'SANDBOX_RUNNER_DEFAULT_CPU_PERCENT=%s\n' "${N8N_SANDBOX_CPU_PERCENT:-100}"
      printf 'SANDBOX_RUNNER_DEFAULT_PIDS_MAX=%s\n' "${N8N_SANDBOX_PIDS_MAX:-256}"
    } >"${temp_env}"
    multipass transfer "${ASSET_DIR}/compose.yml" "${VM_NAME}:/tmp/n8n-sandbox-compose.yml"
    multipass transfer "${ASSET_DIR}/provision_guest.sh" "${VM_NAME}:/tmp/n8n-sandbox-provision.sh"
    multipass transfer "${temp_env}" "${VM_NAME}:/tmp/n8n-sandbox.env"
    multipass exec "${VM_NAME}" -- sudo env SANDBOX_VM_BIND_IP="${resolved_ip}" \
      SANDBOX_HOST_GATEWAY="${host_gateway}" \
      SANDBOX_HOST_SSH_USER="${HOST_SSH_USER}" \
      SANDBOX_HOST_PROXY_PORT="${HOST_PROXY_PORT}" \
      bash /tmp/n8n-sandbox-provision.sh
    printf 'endpoint=http://%s:8080\n' "${resolved_ip}"
    ;;
  start)
    vm_exists || die "VM '${VM_NAME}' does not exist; run: ./agent n8n-sandbox-vm create"
    [[ "$(vm_state)" == "Running" ]] || multipass start "${VM_NAME}"
    resolved_ip="$(vm_ip)"
    host_gateway="$(vm_gateway)"
    install_restricted_tunnel_key
    multipass transfer "${ASSET_DIR}/compose.yml" "${VM_NAME}:/tmp/n8n-sandbox-compose.yml"
    multipass transfer "${ASSET_DIR}/provision_guest.sh" "${VM_NAME}:/tmp/n8n-sandbox-provision.sh"
    multipass exec "${VM_NAME}" -- sudo install -m 0640 \
      /tmp/n8n-sandbox-compose.yml /opt/n8n-sandbox/compose.yml
    multipass exec "${VM_NAME}" -- sudo install -m 0750 \
      /tmp/n8n-sandbox-provision.sh /opt/n8n-sandbox/provision_guest.sh
    multipass exec "${VM_NAME}" -- sudo env SANDBOX_VM_BIND_IP="${resolved_ip}" \
      SANDBOX_HOST_GATEWAY="${host_gateway}" SANDBOX_HOST_SSH_USER="${HOST_SSH_USER}" \
      SANDBOX_HOST_PROXY_PORT="${HOST_PROXY_PORT}" \
      bash /opt/n8n-sandbox/provision_guest.sh --runtime-only
    printf 'endpoint=http://%s:8080\n' "${resolved_ip}"
    ;;
  stop)
    vm_exists || { info "VM '${VM_NAME}' does not exist"; exit 0; }
    [[ "$(vm_state)" != "Running" ]] || multipass stop "${VM_NAME}"
    ;;
  endpoint)
    vm_exists || die "VM '${VM_NAME}' does not exist"
    [[ "$(vm_state)" == "Running" ]] || die "VM '${VM_NAME}' is not running"
    resolved_ip="$(vm_ip)"
    [[ -n "${resolved_ip}" ]] || die "cannot resolve VM private IP"
    printf 'http://%s:8080\n' "${resolved_ip}"
    ;;
  status)
    if ! vm_exists; then
      printf 'name=%s state=absent\n' "${VM_NAME}"
      exit 1
    fi
    state="$(vm_state)"
    resolved_ip="$(vm_ip)"
    health="stopped"
    if [[ "${state}" == "Running" ]]; then
      health="unhealthy"
      runner_health="$(multipass exec "${VM_NAME}" -- sudo docker inspect \
        --format '{{.State.Health.Status}}' n8n-sandbox-runner-1 2>/dev/null || true)"
      tunnel_health="$(multipass exec "${VM_NAME}" -- systemctl is-active \
        n8n-sandbox-egress-tunnel.service 2>/dev/null || true)"
      if [[ "${runner_health}" == "healthy" && "${tunnel_health}" == "active" ]] && \
        curl -fsS --max-time 3 "http://${resolved_ip}:8080/healthz" >/dev/null 2>&1; then
        health="healthy"
      fi
    fi
    printf 'name=%s state=%s ip=%s health=%s runner=%s egress_tunnel=%s\n' \
      "${VM_NAME}" "${state}" "${resolved_ip:-none}" "${health}" \
      "${runner_health:-stopped}" "${tunnel_health:-stopped}"
    [[ "${health}" == "healthy" ]]
    ;;
  destroy)
    vm_exists || { info "VM '${VM_NAME}' does not exist"; exit 0; }
    [[ "${confirmed}" == "1" ]] || die "destructive action requires --yes"
    [[ "$(vm_state)" != "Running" ]] || multipass stop "${VM_NAME}"
    multipass delete "${VM_NAME}"
    remove_restricted_tunnel_key
    info "VM deleted but recoverable until an explicit 'multipass purge'"
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac
