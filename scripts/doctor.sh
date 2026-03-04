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
openclaw_webhook_host_port="${OPENCLAW_WEBHOOK_HOST_PORT:-18111}"

service_requires_proxy_env() {
  local service="$1"
  case "${service}" in
    agentic-claude|agentic-codex|agentic-opencode|agentic-vibestral|openwebui|openhands|comfyui|optional-openclaw|optional-openclaw-sandbox|optional-mcp-catalog|optional-pi-mono|optional-goose|ollama-gate)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

service_allows_root_user() {
  local service="$1"
  case "${service}" in
    ollama|unbound|egress-proxy|promtail|cadvisor|dcgm-exporter)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

service_allows_readwrite_rootfs() {
  local service="$1"
  case "${service}" in
    ollama|egress-proxy|opensearch)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

service_is_agent_cli() {
  local service="$1"
  case "${service}" in
    agentic-claude|agentic-codex|agentic-opencode|agentic-vibestral)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

assert_agent_sudo_mode_hardening() {
  local cid="$1"
  local inspect_out readonly cap_drop security_opt

  inspect_out="$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}|{{join .HostConfig.CapDrop ","}}|{{json .HostConfig.SecurityOpt}}' "${cid}" 2>/dev/null)" \
    || fail "cannot inspect container ${cid}"

  IFS='|' read -r readonly cap_drop security_opt <<<"${inspect_out}"

  [[ "${readonly}" == "true" ]] || {
    fail "${cid}: readonly rootfs is not enabled"
    return 1
  }
  [[ ",${cap_drop}," == *",ALL,"* ]] || {
    fail "${cid}: cap_drop does not include ALL"
    return 1
  }
  [[ "${security_opt}" == *"no-new-privileges:false"* ]] || {
    fail "${cid}: expected no-new-privileges:false in sudo mode"
    return 1
  }

  return 0
}

mount_destination_present() {
  local cid="$1"
  local destination="$2"
  local mounts
  mounts="$(docker inspect --format '{{range .Mounts}}{{printf "%s|%v\n" .Destination .RW}}{{end}}' "${cid}" 2>/dev/null || true)"
  awk -F'|' -v d="${destination}" '$1 == d { found=1 } END { exit(found ? 0 : 1) }' <<<"${mounts}"
}

mount_destination_read_only() {
  local cid="$1"
  local destination="$2"
  local mounts
  mounts="$(docker inspect --format '{{range .Mounts}}{{printf "%s|%v\n" .Destination .RW}}{{end}}' "${cid}" 2>/dev/null || true)"
  awk -F'|' -v d="${destination}" '$1 == d && $2 == "false" { found=1 } END { exit(found ? 0 : 1) }' <<<"${mounts}"
}

allowlist_has_entry() {
  local allowlist_file="$1"
  local entry="$2"
  grep -Fxiq -- "${entry}" "${allowlist_file}"
}

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
if [[ "${AGENTIC_AGENT_NO_NEW_PRIVILEGES}" == "false" ]]; then
  warn "agent sudo-mode is enabled (AGENTIC_AGENT_NO_NEW_PRIVILEGES=false)"
fi

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

mapfile -t running_services < <(
  docker ps \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --format '{{.ID}}|{{.Label "com.docker.compose.service"}}' | sort -t'|' -k2,2
)

for row in "${running_services[@]}"; do
  cid="${row%%|*}"
  service="${row#*|}"
  [[ -n "${cid}" && -n "${service}" ]] || continue

  state="$(docker inspect --format '{{.State.Status}}' "${cid}" 2>/dev/null || true)"
  healthcheck_cfg="$(docker inspect --format '{{if .Config.Healthcheck}}present{{else}}missing{{end}}' "${cid}" 2>/dev/null || true)"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null || true)"

  if [[ "${state}" != "running" ]]; then
    doctor_fail "service '${service}' is not running (state=${state})"
    continue
  fi
  if [[ "${healthcheck_cfg}" != "present" ]]; then
    doctor_fail_or_warn "service '${service}' is missing a healthcheck"
    continue
  fi
  if [[ "${health}" != "healthy" ]]; then
    doctor_fail_or_warn "service '${service}' health is not healthy (health=${health})"
    continue
  fi
  ok "service '${service}' is running and healthy"

  if ! assert_no_docker_sock_mount "${cid}"; then
    doctor_fail_or_warn "docker.sock mount detected for service '${service}'"
  fi

  if service_allows_readwrite_rootfs "${service}"; then
    if ! assert_container_runtime_restrictions "${cid}"; then
      doctor_fail_or_warn "service '${service}' runtime restriction baseline failed"
    fi
  else
    if [[ "${AGENTIC_AGENT_NO_NEW_PRIVILEGES}" == "false" ]] && service_is_agent_cli "${service}"; then
      if ! assert_agent_sudo_mode_hardening "${cid}"; then
        doctor_fail_or_warn "service '${service}' hardening baseline failed in sudo mode"
      fi
    else
      if ! assert_container_hardening "${cid}"; then
        doctor_fail_or_warn "service '${service}' hardening baseline failed"
      fi
    fi
  fi

  if ! service_allows_root_user "${service}"; then
    if ! assert_container_non_root_user "${cid}"; then
      doctor_fail_or_warn "service '${service}' must run as non-root"
    fi
  fi

  if service_requires_proxy_env "${service}"; then
    if ! assert_proxy_enforced "${cid}"; then
      doctor_fail_or_warn "proxy env baseline failed for service '${service}'"
    fi
  fi

  if [[ "${service}" == "gate-mcp" ]]; then
    published="$(docker port "${cid}" 8123/tcp 2>/dev/null || true)"
    [[ -z "${published}" ]] || doctor_fail "gate-mcp must not publish host port 8123 (got: ${published})"

    env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null || true)"
    if ! echo "${env_dump}" | grep -q '^GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token$'; then
      doctor_fail "gate-mcp missing GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token"
    fi
    if ! echo "${env_dump}" | grep -q '^GATE_MCP_AUDIT_LOG=/logs/audit.jsonl$'; then
      doctor_fail "gate-mcp missing GATE_MCP_AUDIT_LOG=/logs/audit.jsonl"
    fi

    if ! mount_destination_present "${cid}" "/run/secrets/gate_mcp.token"; then
      doctor_fail "gate-mcp must mount /run/secrets/gate_mcp.token"
    elif ! mount_destination_read_only "${cid}" "/run/secrets/gate_mcp.token"; then
      doctor_fail "gate-mcp must mount /run/secrets/gate_mcp.token read-only"
    fi

    if ! mount_destination_present "${cid}" "/logs"; then
      doctor_fail "gate-mcp must mount /logs for audit persistence"
    fi
  fi
done

rag_retriever_cid="$(service_container_id rag-retriever)"
if [[ -n "${rag_retriever_cid}" ]]; then
  published="$(docker port "${rag_retriever_cid}" 7111/tcp 2>/dev/null || true)"
  [[ -z "${published}" ]] || doctor_fail "rag-retriever must not publish host port 7111 (got: ${published})"
fi

rag_worker_cid="$(service_container_id rag-worker)"
if [[ -n "${rag_worker_cid}" ]]; then
  published="$(docker port "${rag_worker_cid}" 7112/tcp 2>/dev/null || true)"
  [[ -z "${published}" ]] || doctor_fail "rag-worker must not publish host port 7112 (got: ${published})"
fi

opensearch_cid="$(service_container_id opensearch)"
if [[ -n "${opensearch_cid}" ]]; then
  published="$(docker port "${opensearch_cid}" 9200/tcp 2>/dev/null || true)"
  [[ -z "${published}" ]] || doctor_fail "opensearch must not publish host port 9200 (got: ${published})"
fi

agents_found=0
for service in agentic-claude agentic-codex agentic-opencode agentic-vibestral; do
  cid="$(service_container_id "${service}")"
  [[ -n "${cid}" ]] || continue
  agents_found=1

  env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null || true)"
  if ! echo "${env_dump}" | grep -q '^GATE_MCP_URL=http://gate-mcp:8123$'; then
    doctor_fail "agent '${service}' missing GATE_MCP_URL=http://gate-mcp:8123"
  fi
  if ! echo "${env_dump}" | grep -q '^GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token$'; then
    doctor_fail "agent '${service}' missing GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token"
  fi
  if ! echo "${env_dump}" | grep -q '^HOME=/state/home$'; then
    doctor_fail "agent '${service}' must set HOME=/state/home"
  fi

  if ! mount_destination_present "${cid}" "/run/secrets/gate_mcp.token"; then
    doctor_fail "agent '${service}' must mount /run/secrets/gate_mcp.token read-only"
  elif ! mount_destination_read_only "${cid}" "/run/secrets/gate_mcp.token"; then
    doctor_fail "agent '${service}' must mount /run/secrets/gate_mcp.token read-only"
  fi

  primary_cli="$(printf '%s\n' "${env_dump}" | awk -F= '/^AGENT_PRIMARY_CLI=/{print $2; exit}')"
  if [[ -z "${primary_cli}" ]]; then
    doctor_fail "agent '${service}' missing AGENT_PRIMARY_CLI"
  else
    if ! timeout 15 docker exec "${cid}" sh -lc "command -v ${primary_cli} >/dev/null"; then
      doctor_fail "agent '${service}' primary CLI '${primary_cli}' is missing"
    fi
  fi

  if ! timeout 15 docker exec "${cid}" sh -lc 'test -d /state/home && test -w /state/home'; then
    doctor_fail "agent '${service}' home directory is not writable (/state/home)"
  fi

  if [[ "${AGENTIC_AGENT_NO_NEW_PRIVILEGES}" == "false" ]]; then
    if ! timeout 15 docker exec "${cid}" sh -lc 'command -v sudo >/dev/null && sudo -n true'; then
      doctor_fail "agent '${service}' sudo-mode is enabled but sudo -n true failed"
    fi
  fi
done

if [[ "${agents_found}" -eq 0 ]]; then
  warn "no agent containers running; skipped agent confinement checks"
fi

gate_mcp_token_file="${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token"
if [[ ! -s "${gate_mcp_token_file}" ]]; then
  doctor_fail "gate MCP token is missing or empty: ${gate_mcp_token_file}"
else
  token_mode="$(stat -c '%a' "${gate_mcp_token_file}" 2>/dev/null || true)"
  if [[ "${token_mode}" != "600" && "${token_mode}" != "640" ]]; then
    doctor_fail "gate MCP token permissions must be 600/640: ${gate_mcp_token_file} (mode=${token_mode:-unknown})"
  fi
fi

if [[ ! -d "${AGENTIC_ROOT}/gate/mcp/logs" ]]; then
  doctor_fail "gate MCP audit log directory is missing: ${AGENTIC_ROOT}/gate/mcp/logs"
fi

comfyui_cid="$(service_container_id comfyui)"
if [[ -n "${comfyui_cid}" ]]; then
  allowlist_file="${AGENTIC_ROOT}/proxy/allowlist.txt"
  if [[ ! -f "${allowlist_file}" ]]; then
    doctor_fail_or_warn "proxy allowlist file is missing: ${allowlist_file}"
  else
    for required_domain in api.comfy.org registry.comfy.org; do
      if ! allowlist_has_entry "${allowlist_file}" "${required_domain}"; then
        doctor_fail_or_warn "proxy allowlist missing required ComfyUI domain '${required_domain}' in ${allowlist_file}"
      fi
    done
  fi
fi

optional_openclaw_cid="$(service_container_id optional-openclaw)"
if [[ -n "${optional_openclaw_cid}" ]]; then
  if ! assert_no_public_bind "${openclaw_webhook_host_port}"; then
    doctor_fail "optional openclaw webhook bind must stay loopback-only on port ${openclaw_webhook_host_port}"
  fi
fi

optional_portainer_cid="$(service_container_id optional-portainer)"
if [[ -n "${optional_portainer_cid}" ]]; then
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
    legacy_release_images_file="$(find "${current_release_dir}" -mindepth 2 -maxdepth 2 -type f -name images.json 2>/dev/null | sort | tail -n 1 || true)"
    if [[ -n "${legacy_release_images_file}" && -s "${legacy_release_images_file}" ]]; then
      warn "legacy current release layout detected (${legacy_release_images_file}); run 'agent update' to migrate current/ to symlink mode"
      ok "active release images manifest is present"
    else
      doctor_fail_or_warn "active release is missing images manifest: ${release_images_file}"
    fi
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
