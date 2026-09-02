#!/usr/bin/env bash
set -euo pipefail

SYSBOX_VERSION="${SYSBOX_VERSION:-0.7.0}"
SYSBOX_SHA256_AMD64="eeff273671467b8fa351ab3d40709759462dc03d9f7b50a1b207b37982ce40a9"
SYSBOX_SHA256_ARM64="eae9c0e91ddd39bd1826d6a7a313a73d42a8449ef5113e9d6d118b559cb809ba"
INSTALL_ROOT="/opt/n8n-sandbox"
STATE_ROOT="/srv/n8n-sandbox"
ENV_ROOT="/etc/n8n-sandbox"
RUNTIME_ONLY=0

if [[ "${1:-}" == "--runtime-only" ]]; then
  RUNTIME_ONLY=1
fi

[[ "${EUID}" -eq 0 ]] || { echo "ERROR: provision_guest.sh must run as root" >&2; exit 1; }
if [[ "${RUNTIME_ONLY}" == "0" ]]; then
  [[ -s /tmp/n8n-sandbox-compose.yml ]] || { echo "ERROR: missing transferred compose file" >&2; exit 1; }
  [[ -s /tmp/n8n-sandbox.env ]] || { echo "ERROR: missing transferred environment file" >&2; exit 1; }
fi
[[ "${SANDBOX_VM_BIND_IP:-}" =~ ^10\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "ERROR: invalid SANDBOX_VM_BIND_IP" >&2; exit 1; }
[[ "${SANDBOX_HOST_GATEWAY:-}" =~ ^10\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "ERROR: invalid SANDBOX_HOST_GATEWAY" >&2; exit 1; }
[[ "${SANDBOX_HOST_SSH_USER:-}" =~ ^[a-z_][a-z0-9_-]*$ ]] \
  || { echo "ERROR: invalid SANDBOX_HOST_SSH_USER" >&2; exit 1; }
[[ "${SANDBOX_HOST_PROXY_PORT:-}" =~ ^[0-9]+$ ]] \
  || { echo "ERROR: invalid SANDBOX_HOST_PROXY_PORT" >&2; exit 1; }
SANDBOX_PROXY_VIRTUAL_IP="${SANDBOX_PROXY_VIRTUAL_IP:-192.0.2.1}"

if [[ "${RUNTIME_ONLY}" == "0" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends docker.io docker-compose-v2 curl ca-certificates jq >/dev/null
  systemctl enable --now docker
  modprobe br_netfilter
  printf 'br_netfilter\n' >/etc/modules-load.d/n8n-sandbox-br-netfilter.conf
fi

if [[ "${RUNTIME_ONLY}" == "0" ]] && ! docker info --format '{{json .Runtimes}}' 2>/dev/null | jq -e '."sysbox-runc"' >/dev/null; then
  case "$(uname -m)" in
    aarch64)
      sysbox_arch="arm64"
      sysbox_sha="${SYSBOX_SHA256_ARM64}"
      ;;
    x86_64)
      sysbox_arch="amd64"
      sysbox_sha="${SYSBOX_SHA256_AMD64}"
      ;;
    *)
      echo "ERROR: unsupported Sysbox architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
  sysbox_deb="/tmp/sysbox-ce_${SYSBOX_VERSION}-0.linux_${sysbox_arch}.deb"
  curl -fL --retry 3 --output "${sysbox_deb}" \
    "https://downloads.nestybox.com/sysbox/releases/v${SYSBOX_VERSION}/sysbox-ce_${SYSBOX_VERSION}-0.linux_${sysbox_arch}.deb"
  printf '%s  %s\n' "${sysbox_sha}" "${sysbox_deb}" | sha256sum -c -
  apt-get install -y "${sysbox_deb}" >/dev/null
  rm -f "${sysbox_deb}"
fi

docker info --format '{{json .Runtimes}}' | jq -e '."sysbox-runc"' >/dev/null \
  || { echo "ERROR: sysbox-runc was not registered in guest Docker" >&2; exit 1; }

if [[ "${RUNTIME_ONLY}" == "0" ]]; then
  install -d -m 0750 "${INSTALL_ROOT}" "${STATE_ROOT}" "${ENV_ROOT}"
  install -d -m 0750 \
    "${STATE_ROOT}/api-data" \
    "${STATE_ROOT}/docker-data" \
    "${STATE_ROOT}/release" \
    "${STATE_ROOT}/registry" \
    "${STATE_ROOT}/runner-data" \
    "${STATE_ROOT}/tls"
  chown 100:101 "${STATE_ROOT}/api-data"
  install -m 0640 /tmp/n8n-sandbox-compose.yml "${INSTALL_ROOT}/compose.yml"
  install -m 0750 /tmp/n8n-sandbox-provision.sh "${INSTALL_ROOT}/provision_guest.sh"
  install -m 0600 /tmp/n8n-sandbox.env "${ENV_ROOT}/sandbox.env"
  rm -f /tmp/n8n-sandbox-compose.yml /tmp/n8n-sandbox.env /tmp/n8n-sandbox-provision.sh
fi

install -d -m 0700 /root/.ssh
ssh-keyscan -H "${SANDBOX_HOST_GATEWAY}" >/root/.ssh/n8n-sandbox-host-known_hosts 2>/dev/null
chmod 0600 /root/.ssh/n8n-sandbox-host-known_hosts

cat >/etc/systemd/system/n8n-sandbox-egress-tunnel.service <<EOF
[Unit]
Description=Restricted tunnel to the monitored agentic egress proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ssh -NT -g -i /etc/n8n-sandbox/egress_tunnel_ed25519 -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o UserKnownHostsFile=/root/.ssh/n8n-sandbox-host-known_hosts -L ${SANDBOX_VM_BIND_IP}:3128:127.0.0.1:${SANDBOX_HOST_PROXY_PORT} ${SANDBOX_HOST_SSH_USER}@${SANDBOX_HOST_GATEWAY}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now n8n-sandbox-egress-tunnel.service

for _attempt in $(seq 1 20); do
  if curl -fsS --max-time 5 --proxy "http://${SANDBOX_VM_BIND_IP}:3128" https://example.com >/dev/null; then
    break
  fi
  if [[ "${_attempt}" == "20" ]]; then
    systemctl status --no-pager n8n-sandbox-egress-tunnel.service || true
    echo "ERROR: monitored egress tunnel did not become ready" >&2
    exit 1
  fi
  sleep 1
done

# Fail closed for every container subnet in this guest. Internal bridge traffic
# and the VM-local proxy tunnel remain available; direct forwarded egress does not.
iptables -N AGENTIC-SANDBOX-EGRESS 2>/dev/null || true
iptables -F AGENTIC-SANDBOX-EGRESS
iptables -C DOCKER-USER -j AGENTIC-SANDBOX-EGRESS 2>/dev/null \
  || iptables -I DOCKER-USER 1 -j AGENTIC-SANDBOX-EGRESS
iptables -A AGENTIC-SANDBOX-EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
for subnet in 172.30.10.0/24 172.30.11.0/24 172.30.12.0/24 172.30.13.0/24; do
  iptables -A AGENTIC-SANDBOX-EGRESS -s "${subnet}" -d 172.30.0.0/16 -j ACCEPT
  iptables -A AGENTIC-SANDBOX-EGRESS -s "${subnet}" \
    -d "${SANDBOX_VM_BIND_IP}/32" -p tcp --dport 3128 -j ACCEPT
  iptables -A AGENTIC-SANDBOX-EGRESS -s "${subnet}" -j DROP
done
iptables -A AGENTIC-SANDBOX-EGRESS -j RETURN

# n8n's own policy rejects RFC1918 destinations before our inner chain. Use a
# non-routable RFC5737 address in sandbox configs and translate it only here,
# inside the VM, to the SSH tunnel listener.
iptables -t nat -N AGENTIC-SANDBOX-PROXY 2>/dev/null || true
iptables -t nat -F AGENTIC-SANDBOX-PROXY
iptables -t nat -C PREROUTING -j AGENTIC-SANDBOX-PROXY 2>/dev/null \
  || iptables -t nat -I PREROUTING 1 -j AGENTIC-SANDBOX-PROXY
for subnet in 172.30.10.0/24 172.30.11.0/24 172.30.12.0/24 172.30.13.0/24; do
  iptables -t nat -A AGENTIC-SANDBOX-PROXY -s "${subnet}" \
    -d "${SANDBOX_PROXY_VIRTUAL_IP}/32" -p tcp --dport 3128 \
    -j DNAT --to-destination "${SANDBOX_VM_BIND_IP}:3128"
done

compose_up_args=(-d)
if [[ "${RUNTIME_ONLY}" == "0" ]]; then
  # The inner daemon persists across runner recreation. Remove only our derived
  # tag so the runner cannot reuse a stale proxy-policy image after reprovision.
  docker exec n8n-sandbox-runner-1 docker image rm -f \
    registry:5000/n8n-sandbox:proxied >/dev/null 2>&1 || true
  docker compose --project-name n8n-sandbox --env-file "${ENV_ROOT}/sandbox.env" \
    -f "${INSTALL_ROOT}/compose.yml" down --remove-orphans
  compose_up_args+=(--force-recreate)
else
  # The runner's HTTP health endpoint can stay green after its long-lived gRPC
  # registration has disappeared from the API. Recreate only the stateless
  # runner control process so every explicit VM start re-registers it; its
  # inner Docker data remains on the persistent runner-data/docker-data mounts.
  compose_up_args+=(--force-recreate runner)
fi
docker compose --project-name n8n-sandbox --env-file "${ENV_ROOT}/sandbox.env" \
  -f "${INSTALL_ROOT}/compose.yml" up "${compose_up_args[@]}"

for _attempt in $(seq 1 60); do
  runner_health="$(docker inspect --format '{{.State.Health.Status}}' n8n-sandbox-runner-1 2>/dev/null || true)"
  [[ "${runner_health}" == "healthy" ]] && break
  sleep 2
done
[[ "${runner_health:-}" == "healthy" ]] \
  || { echo "ERROR: n8n sandbox runner did not become healthy" >&2; exit 1; }

runner_bridge_id="$(docker exec n8n-sandbox-runner-1 docker network inspect runner-bridge --format '{{.Id}}')"
runner_bridge="br-${runner_bridge_id:0:12}"
docker exec n8n-sandbox-runner-1 iptables -N AGENTIC-SBX-EGRESS 2>/dev/null || true
docker exec n8n-sandbox-runner-1 iptables -F AGENTIC-SBX-EGRESS
docker exec n8n-sandbox-runner-1 iptables -C DOCKER-USER -i "${runner_bridge}" -j AGENTIC-SBX-EGRESS 2>/dev/null \
  || docker exec n8n-sandbox-runner-1 iptables -I DOCKER-USER 1 -i "${runner_bridge}" -j AGENTIC-SBX-EGRESS
docker exec n8n-sandbox-runner-1 iptables -A AGENTIC-SBX-EGRESS \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
docker exec n8n-sandbox-runner-1 iptables -A AGENTIC-SBX-EGRESS \
  -d "${SANDBOX_PROXY_VIRTUAL_IP}/32" -p tcp --dport 3128 -j ACCEPT
docker exec n8n-sandbox-runner-1 iptables -A AGENTIC-SBX-EGRESS -j DROP

docker exec n8n-sandbox-runner-1 iptables -C INPUT -i "${runner_bridge}" \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || docker exec n8n-sandbox-runner-1 iptables -I INPUT 1 -i "${runner_bridge}" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
docker exec n8n-sandbox-runner-1 iptables -C INPUT -i "${runner_bridge}" -j DROP 2>/dev/null \
  || docker exec n8n-sandbox-runner-1 iptables -A INPUT -i "${runner_bridge}" -j DROP

for _attempt in $(seq 1 60); do
  runner_health="$(docker inspect --format '{{.State.Health.Status}}' n8n-sandbox-runner-1 2>/dev/null || true)"
  if [[ "${runner_health}" == "healthy" ]] && \
    curl -fsS --max-time 2 "http://${SANDBOX_VM_BIND_IP}:8080/healthz" >/dev/null; then
    manifest_tmp="$(mktemp)"
    docker compose --project-name n8n-sandbox --env-file "${ENV_ROOT}/sandbox.env" \
      -f "${INSTALL_ROOT}/compose.yml" images --format json >"${manifest_tmp}"
    docker exec n8n-sandbox-runner-1 docker image inspect \
      registry:5000/n8n-sandbox:proxied --format \
      'inner-sandbox {{.Id}} {{join .RepoDigests " "}}' >>"${manifest_tmp}"
    install -m 0640 "${manifest_tmp}" "${STATE_ROOT}/release/images.txt"
    rm -f "${manifest_tmp}"
    echo "n8n sandbox VM is healthy at http://${SANDBOX_VM_BIND_IP}:8080"
    exit 0
  fi
  sleep 2
done

docker compose --project-name n8n-sandbox --env-file "${ENV_ROOT}/sandbox.env" \
  -f "${INSTALL_ROOT}/compose.yml" ps
echo "ERROR: n8n sandbox API did not become healthy" >&2
exit 1
