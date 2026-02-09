#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  return 1
}

ok() {
  echo "OK: $*"
}

warn() {
  echo "WARN: $*" >&2
}

assert_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "command not found: ${cmd}"
  ok "command available: ${cmd}"
}

assert_no_public_bind() {
  assert_cmd ss
  local -a ports=("$@")
  if [[ "${#ports[@]}" -eq 0 ]]; then
    ports=(11434 8080 3000 8188 9090 3100 9100)
  fi

  local port
  local bad=0
  for port in "${ports[@]}"; do
    while IFS= read -r addr; do
      case "$addr" in
        127.0.0.1:*|[::1]:*) ;;
        *)
          echo "FAIL: port ${port} has non-loopback listener: ${addr}" >&2
          bad=1
          ;;
      esac
    done < <(ss -lntH 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" { print $4 }')
  done

  [[ "$bad" -eq 0 ]] || return 1
  ok "all checked ports are loopback-only"
}

assert_container_security() {
  local container="$1"
  assert_cmd docker

  local inspect_out
  inspect_out="$(docker inspect --format '{{.Config.User}}|{{.HostConfig.ReadonlyRootfs}}|{{join .HostConfig.CapDrop ","}}|{{json .HostConfig.SecurityOpt}}' "$container" 2>/dev/null)" || fail "cannot inspect container ${container}"

  local user readonly cap_drop security_opt
  IFS='|' read -r user readonly cap_drop security_opt <<<"$inspect_out"

  [[ -n "$user" && "$user" != "0" && "$user" != "root" ]] || fail "${container}: container user is root or empty"
  [[ "$readonly" == "true" ]] || fail "${container}: readonly rootfs is not enabled"
  [[ ",$cap_drop," == *",ALL,"* ]] || fail "${container}: cap_drop does not include ALL"
  [[ "$security_opt" == *"no-new-privileges:true"* ]] || fail "${container}: no-new-privileges is missing"

  ok "container security baseline is satisfied for ${container}"
}

assert_proxy_enforced() {
  local container="$1"
  assert_cmd docker

  local env_dump
  env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null)" || fail "cannot inspect env for container ${container}"

  echo "$env_dump" | grep -q '^HTTP_PROXY=' || fail "${container}: HTTP_PROXY is missing"
  echo "$env_dump" | grep -q '^HTTPS_PROXY=' || fail "${container}: HTTPS_PROXY is missing"

  ok "proxy env is enforced for ${container}"
}

service_container_id() {
  local service="$1"
  local project="${AGENTIC_COMPOSE_PROJECT:-agentic}"

  docker ps \
    --filter "label=com.docker.compose.project=${project}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}' | head -n 1
}

require_service_container() {
  local service="$1"
  local container_id
  container_id="$(service_container_id "$service")"
  [[ -n "$container_id" ]] || fail "service '${service}' is not running in compose project '${AGENTIC_COMPOSE_PROJECT:-agentic}'"
  printf '%s\n' "$container_id"
}

wait_for_container_ready() {
  local container_id="$1"
  local timeout_seconds="${2:-45}"
  local elapsed=0
  local state
  local health

  while (( elapsed < timeout_seconds )); do
    state="$(docker inspect --format '{{.State.Status}}' "${container_id}" 2>/dev/null || true)"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${container_id}" 2>/dev/null || true)"

    if [[ "${state}" == "running" ]]; then
      if [[ -z "${health}" || "${health}" == "healthy" ]]; then
        return 0
      fi
    fi

    sleep 1
    ((elapsed += 1))
  done

  fail "container '${container_id}' did not become ready within ${timeout_seconds}s (state=${state}, health=${health})"
}

assert_network_internal() {
  local network_name="${1:-${AGENTIC_NETWORK:-agentic}}"
  assert_cmd docker

  local internal_flag
  internal_flag="$(docker network inspect "$network_name" --format '{{.Internal}}' 2>/dev/null)" \
    || fail "docker network '${network_name}' does not exist"

  [[ "$internal_flag" == "true" ]] || fail "docker network '${network_name}' must be internal=true (actual=${internal_flag})"
  ok "docker network '${network_name}' is internal"
}

assert_docker_user_policy() {
  assert_cmd iptables

  local chain="${AGENTIC_DOCKER_USER_CHAIN:-AGENTIC-DOCKER-USER}"
  local docker_user_rules
  local chain_rules

  docker_user_rules="$(iptables -S DOCKER-USER 2>/dev/null)" || fail "iptables chain DOCKER-USER is missing"
  echo "$docker_user_rules" | grep -Fq -- "-j ${chain}" || fail "DOCKER-USER does not jump to ${chain}"

  chain_rules="$(iptables -S "${chain}" 2>/dev/null)" || fail "iptables chain '${chain}' is missing"
  echo "$chain_rules" | grep -Fq -- "-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" \
    || fail "${chain}: ESTABLISHED,RELATED accept rule missing"
  echo "$chain_rules" | grep -Fq -- "--log-prefix \"AGENTIC-DROP \"" \
    || fail "${chain}: LOG rule with AGENTIC-DROP prefix missing"
  echo "$chain_rules" | grep -Fq -- "-j DROP" || fail "${chain}: DROP rule missing"

  ok "DOCKER-USER enforcement chain '${chain}' is present"
}
