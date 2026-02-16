#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"
# shellcheck source=tests/lib/common.sh
source "${AGENTIC_REPO_ROOT}/tests/lib/common.sh"

status=0
fix_net=0

warn() {
  echo "WARN: $*" >&2
}

doctor_fail() {
  echo "FAIL: $*" >&2
  status=1
}

doctor_fail_or_warn() {
  local message="$1"
  if [[ "${AGENTIC_PROFILE}" == "strict-prod" ]]; then
    doctor_fail "${message}"
  else
    warn "${message}"
  fi
}

usage() {
  cat <<USAGE
Usage:
  agent doctor [--fix-net]

Environment:
  AGENTIC_PROFILE=strict-prod|rootless-dev
USAGE
}

critical_ports=()
if [[ -n "${AGENTIC_DOCTOR_CRITICAL_PORTS:-}" ]]; then
  read -r -a critical_ports <<<"${AGENTIC_DOCTOR_CRITICAL_PORTS//,/ }"
fi
portainer_host_port="${PORTAINER_HOST_PORT:-9001}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix-net)
      fix_net=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      doctor_fail "unknown doctor argument: $1"
      usage
      exit "$status"
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  doctor_fail "docker command not found; stack is not ready"
  exit "$status"
fi

if ! docker info >/dev/null 2>&1; then
  doctor_fail "docker daemon unavailable; stack is not ready"
  exit "$status"
fi

ok "doctor profile=${AGENTIC_PROFILE}"

if [[ "${#critical_ports[@]}" -gt 0 ]]; then
  if ! assert_no_public_bind "${critical_ports[@]}"; then
    doctor_fail "one or more configured critical ports are exposed on a non-loopback interface"
  fi
else
  if ! assert_no_public_bind; then
    doctor_fail "one or more critical ports are exposed on a non-loopback interface"
  fi
fi

running_count="$(docker ps --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" --format '{{.Names}}' | wc -l | tr -d ' ')"
if [[ "$running_count" -eq 0 ]]; then
  doctor_fail "no containers deployed for compose project '${AGENTIC_COMPOSE_PROJECT}' (not ready)"
else
  ok "compose project '${AGENTIC_COMPOSE_PROJECT}' has ${running_count} running container(s)"
fi

if [[ "$fix_net" -eq 1 ]]; then
  if [[ "${AGENTIC_SKIP_DOCKER_USER_APPLY:-0}" == "1" ]]; then
    warn "skip network fix because AGENTIC_SKIP_DOCKER_USER_APPLY=1"
  else
    if "${AGENTIC_REPO_ROOT}/deployments/net/apply_docker_user.sh"; then
      ok "DOCKER-USER policy reapplied"
    else
      doctor_fail "unable to reapply DOCKER-USER policy"
    fi
  fi
fi

if [[ "${AGENTIC_SKIP_DOCKER_USER_CHECK:-0}" == "1" ]]; then
  warn "skip DOCKER-USER policy check because AGENTIC_SKIP_DOCKER_USER_CHECK=1"
else
  if ! assert_docker_user_policy; then
    doctor_fail_or_warn "DOCKER-USER policy is missing or incomplete"
  fi
fi

if [[ "${AGENTIC_SKIP_DOCTOR_PROXY_CHECK:-0}" != "1" ]]; then
  toolbox_cid="$(service_container_id toolbox)"
  if [[ -z "${toolbox_cid}" ]]; then
    doctor_fail_or_warn "toolbox container is not running; cannot validate egress policy"
  else
    set +e
    timeout 15 docker exec "${toolbox_cid}" sh -lc \
      'env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY curl -fsS --noproxy "*" --max-time 8 https://example.com >/dev/null'
    direct_rc=$?
    set -e

    if [[ "${direct_rc}" -eq 0 ]]; then
      doctor_fail_or_warn "direct egress from toolbox succeeded; proxy enforcement is broken"
    else
      ok "direct egress from toolbox is blocked"
    fi
  fi
else
  warn "skip proxy enforcement check because AGENTIC_SKIP_DOCTOR_PROXY_CHECK=1"
fi

for service in ollama ollama-gate egress-proxy unbound toolbox openwebui openhands comfyui prometheus grafana loki qdrant optional-sentinel optional-openclaw optional-mcp-catalog optional-pi-mono optional-goose optional-portainer; do
  cid="$(service_container_id "${service}")"
  [[ -n "${cid}" ]] || continue

  state="$(docker inspect --format '{{.State.Status}}' "${cid}" 2>/dev/null || true)"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null || true)"
  if [[ "${state}" != "running" ]]; then
    doctor_fail "service '${service}' is not running (state=${state})"
    continue
  fi
  if [[ "${health}" != "none" && "${health}" != "healthy" ]]; then
    doctor_fail "service '${service}' health is not healthy (health=${health})"
    continue
  fi
  ok "service '${service}' is running and healthy"
done

agents_found=0
for service in agentic-claude agentic-codex agentic-opencode; do
  cid="$(service_container_id "${service}")"
  [[ -n "${cid}" ]] || continue
  agents_found=1

  if ! assert_container_security "${cid}"; then
    doctor_fail "agent container security baseline failed for '${service}'"
  fi
  if ! assert_proxy_enforced "${cid}"; then
    doctor_fail "proxy env baseline failed for '${service}'"
  fi
done

if [[ "${agents_found}" -eq 0 ]]; then
  warn "no agent containers running; skipped agent confinement checks"
fi

for service in optional-openclaw optional-mcp-catalog optional-pi-mono optional-goose; do
  cid="$(service_container_id "${service}")"
  [[ -n "${cid}" ]] || continue

  if ! assert_container_security "${cid}"; then
    doctor_fail "optional module security baseline failed for '${service}'"
  fi
  if ! assert_proxy_enforced "${cid}"; then
    doctor_fail "proxy env baseline failed for optional module '${service}'"
  fi
  if ! assert_no_docker_sock_mount "${cid}"; then
    doctor_fail "docker.sock mount detected for optional module '${service}'"
  fi
done

optional_portainer_cid="$(service_container_id optional-portainer)"
if [[ -n "${optional_portainer_cid}" ]]; then
  if ! assert_container_security "${optional_portainer_cid}"; then
    doctor_fail "optional module security baseline failed for 'optional-portainer'"
  fi
  if ! assert_no_docker_sock_mount "${optional_portainer_cid}"; then
    doctor_fail "docker.sock mount detected for optional module 'optional-portainer'"
  fi
  if ! assert_no_public_bind "${portainer_host_port}"; then
    doctor_fail "optional portainer host bind must stay loopback-only on port ${portainer_host_port}"
  fi
fi

current_release_dir="${AGENTIC_ROOT}/deployments/current"
if [[ ! -L "${current_release_dir}" && ! -d "${current_release_dir}" ]]; then
  doctor_fail_or_warn "no active release snapshot found at ${current_release_dir}"
else
  release_images_file="${current_release_dir}/images.json"
  if [[ ! -s "${release_images_file}" ]]; then
    doctor_fail_or_warn "active release is missing images manifest: ${release_images_file}"
  else
    ok "active release images manifest is present"
  fi
fi

if [[ "$status" -ne 0 ]]; then
  warn "doctor result: NOT READY"
else
  ok "doctor result: READY"
fi

exit "$status"
