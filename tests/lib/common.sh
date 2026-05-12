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

pick_free_loopback_port() {
  local start_port="${1:-20000}"
  local max_tries="${2:-200}"
  local candidate

  for ((candidate=start_port; candidate<start_port+max_tries; candidate++)); do
    if ! ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$candidate$"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  fail "unable to find a free loopback port starting at ${start_port}"
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
  local status=0
  assert_cmd docker

  assert_container_hardening "${container}" || status=1
  assert_container_non_root_user "${container}" || status=1

  [[ "${status}" -eq 0 ]] || return 1
  ok "container security baseline is satisfied for ${container}"
}

inspect_container_security_fields() {
  local container="$1"
  docker inspect --format '{{.Config.User}}|{{.HostConfig.ReadonlyRootfs}}|{{join .HostConfig.CapDrop ","}}|{{json .HostConfig.SecurityOpt}}' "$container" 2>/dev/null
}

assert_container_runtime_restrictions() {
  local container="$1"
  local status=0
  assert_cmd docker

  local inspect_out
  inspect_out="$(inspect_container_security_fields "$container")" \
    || fail "cannot inspect container ${container}"
  [[ -n "${inspect_out}" ]] || return 1

  local _user _readonly cap_drop security_opt
  IFS='|' read -r _user _readonly cap_drop security_opt <<<"$inspect_out"

  [[ ",$cap_drop," == *",ALL,"* ]] || {
    fail "${container}: cap_drop does not include ALL"
    status=1
  }
  [[ "$security_opt" == *"no-new-privileges:true"* ]] || {
    fail "${container}: no-new-privileges is missing"
    status=1
  }

  [[ "${status}" -eq 0 ]] || return 1
  ok "container runtime restrictions are satisfied for ${container}"
}

assert_container_hardening() {
  local container="$1"
  local status=0
  assert_cmd docker

  local inspect_out
  inspect_out="$(inspect_container_security_fields "$container")" \
    || fail "cannot inspect container ${container}"
  [[ -n "${inspect_out}" ]] || return 1

  local _user readonly _cap_drop _security_opt
  IFS='|' read -r _user readonly _cap_drop _security_opt <<<"$inspect_out"

  [[ "$readonly" == "true" ]] || {
    fail "${container}: readonly rootfs is not enabled"
    status=1
  }
  assert_container_runtime_restrictions "${container}" || status=1

  [[ "${status}" -eq 0 ]] || return 1
  ok "container hardening baseline is satisfied for ${container}"
}

assert_container_non_root_user() {
  local container="$1"
  assert_cmd docker

  local inspect_out
  inspect_out="$(inspect_container_security_fields "$container")" \
    || fail "cannot inspect container ${container}"
  [[ -n "${inspect_out}" ]] || return 1

  local user _readonly _cap_drop _security_opt
  IFS='|' read -r user _readonly _cap_drop _security_opt <<<"$inspect_out"

  [[ -n "$user" && "$user" != "0" && "$user" != "root" ]] || {
    fail "${container}: container user is root or empty"
    return 1
  }

  ok "container user is non-root for ${container}"
}

assert_container_security_with_root_exception() {
  local container="$1"
  local status=0
  assert_cmd docker

  assert_container_hardening "${container}" || status=1

  [[ "${status}" -eq 0 ]] || return 1

  ok "container security baseline (root exception allowed) is satisfied for ${container}"
}

assert_proxy_enforced() {
  local container="$1"
  local status=0
  assert_cmd docker

  local env_dump
  env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null)" \
    || fail "cannot inspect env for container ${container}"
  [[ -n "${env_dump}" ]] || return 1

  echo "$env_dump" | grep -q '^HTTP_PROXY=' || {
    fail "${container}: HTTP_PROXY is missing"
    status=1
  }
  echo "$env_dump" | grep -q '^HTTPS_PROXY=' || {
    fail "${container}: HTTPS_PROXY is missing"
    status=1
  }
  echo "$env_dump" | grep -q '^NO_PROXY=' || {
    fail "${container}: NO_PROXY is missing"
    status=1
  }

  [[ "${status}" -eq 0 ]] || return 1

  ok "proxy env is enforced for ${container}"
}

assert_no_docker_sock_mount() {
  local container="$1"
  assert_cmd docker

  local mounts
  mounts="$(docker inspect --format '{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}' "${container}" 2>/dev/null)" \
    || fail "cannot inspect mounts for container ${container}"

  if echo "${mounts}" | grep -Eq '(^|/| )docker\.sock($| |/)|\|/var/run/docker\.sock$'; then
    fail "${container}: docker.sock mount detected"
    return 1
  fi

  ok "docker.sock mount is absent for ${container}"
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
  [[ -n "$container_id" ]] || {
    fail "service '${service}' is not running in compose project '${AGENTIC_COMPOSE_PROJECT:-agentic}'"
    return 1
  }
  printf '%s\n' "$container_id"
}

container_env_value() {
  local container_id="$1"
  local key="$2"
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${container_id}" 2>/dev/null \
    | sed -n "s/^${key}=//p" | head -n 1
}

runtime_env_value() {
  local runtime_root="${1:-${AGENTIC_ROOT:-/srv/agentic}}"
  local key="$2"
  local runtime_env_file="${runtime_root}/deployments/runtime.env"
  [[ -f "${runtime_env_file}" ]] || return 0
  sed -n "s/^${key}=//p" "${runtime_env_file}" | head -n 1
}

container_mount_source() {
  local container_id="$1"
  local destination="$2"
  docker inspect --format '{{range .Mounts}}{{if eq .Destination "'"${destination}"'"}}{{println .Source}}{{end}}{{end}}' "${container_id}" 2>/dev/null \
    | head -n 1
}

resolve_gate_log_path() {
  local gate_container_id="$1"
  local gate_log_file
  local gate_logs_source
  local gate_log_relative

  gate_log_file="$(container_env_value "${gate_container_id}" "GATE_LOG_FILE")"
  gate_log_file="${gate_log_file:-/gate/logs/gate.jsonl}"
  gate_logs_source="$(container_mount_source "${gate_container_id}" "/gate/logs")"
  [[ -n "${gate_logs_source}" ]] || {
    fail "${gate_container_id}: cannot resolve /gate/logs mount source"
    return 1
  }
  case "${gate_log_file}" in
    /gate/logs/*) gate_log_relative="${gate_log_file#/gate/logs/}" ;;
    *) gate_log_relative="$(basename "${gate_log_file}")" ;;
  esac
  printf '%s/%s\n' "${gate_logs_source%/}" "${gate_log_relative}"
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
  [[ -n "${internal_flag}" ]] || return 1

  [[ "$internal_flag" == "true" ]] || {
    fail "docker network '${network_name}' must be internal=true (actual=${internal_flag})"
    return 1
  }
  ok "docker network '${network_name}' is internal"
}

collect_service_ips_for_networks() {
  local service="$1"
  local target_var="$2"
  shift 2
  local -a networks=("$@")
  local cid network_name ip
  local -n target_ref="${target_var}"

  target_ref=()
  cid="$(service_container_id "${service}")"
  [[ -n "${cid}" ]] || return 1

  for network_name in "${networks[@]}"; do
    [[ -n "${network_name}" ]] || continue
    ip="$(docker inspect --format "{{with index .NetworkSettings.Networks \"${network_name}\"}}{{.IPAddress}}{{end}}" "${cid}" 2>/dev/null || true)"
    [[ -n "${ip}" ]] || continue
    target_ref+=("${ip}")
  done

  [[ "${#target_ref[@]}" -gt 0 ]]
}

assert_docker_user_policy() {
  assert_cmd iptables
  assert_cmd docker
  local status=0

  local chain="${AGENTIC_DOCKER_USER_CHAIN:-AGENTIC-DOCKER-USER}"
  local source_networks_raw="${AGENTIC_DOCKER_USER_SOURCE_NETWORKS:-${AGENTIC_NETWORK:-agentic},${AGENTIC_EGRESS_NETWORK:-agentic-egress}}"
  local docker_user_rules
  local chain_rules
  local raw_network
  local network_name
  local subnet
  local src_subnet
  local agentic_subnet
  local egress_network="${AGENTIC_EGRESS_NETWORK:-agentic-egress}"
  local -a proxy_source_ips=()
  local -a proxy_dest_ips=()
  local -a unbound_source_ips=()
  local -a unbound_dest_ips=()
  local -a ollama_source_ips=()
  local -a source_subnets=()
  declare -A seen_source_networks=()

  docker_user_rules="$(iptables -S DOCKER-USER 2>/dev/null)" || {
    fail "iptables chain DOCKER-USER is missing"
    status=1
  }
  if [[ -n "${docker_user_rules:-}" ]]; then
    echo "$docker_user_rules" | grep -Fq -- "-j ${chain}" || {
      fail "DOCKER-USER does not jump to ${chain}"
      status=1
    }
  fi

  chain_rules="$(iptables -S "${chain}" 2>/dev/null)" || {
    fail "iptables chain '${chain}' is missing"
    status=1
  }
  echo "$chain_rules" | grep -Fq -- "-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" \
    || {
      fail "${chain}: ESTABLISHED,RELATED accept rule missing"
      status=1
    }
  echo "$chain_rules" | grep -Fq -- "--log-prefix \"AGENTIC-DROP \"" \
    || {
      fail "${chain}: LOG rule with AGENTIC-DROP prefix missing"
      status=1
    }
  echo "$chain_rules" | grep -Fq -- "-j DROP" || {
    fail "${chain}: DROP rule missing"
    status=1
  }

  agentic_subnet="$(docker network inspect "${AGENTIC_NETWORK:-agentic}" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
  if [[ -z "${agentic_subnet}" ]]; then
    fail "${chain}: unable to resolve subnet for internal network '${AGENTIC_NETWORK:-agentic}'"
    status=1
  fi

  for raw_network in ${source_networks_raw//,/ }; do
    network_name="${raw_network// /}"
    [[ -n "${network_name}" ]] || continue
    if [[ -n "${seen_source_networks[${network_name}]:-}" ]]; then
      continue
    fi
    seen_source_networks["${network_name}"]=1

    subnet="$(docker network inspect "${network_name}" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
    if [[ -z "${subnet}" ]]; then
      fail "${chain}: unable to resolve subnet for source network '${network_name}'"
      status=1
      continue
    fi
    source_subnets+=("${subnet}")
  done

  if [[ "${#source_subnets[@]}" -eq 0 ]]; then
    fail "${chain}: no source subnets resolved from AGENTIC_DOCKER_USER_SOURCE_NETWORKS='${source_networks_raw}'"
    status=1
  fi

  for src_subnet in "${source_subnets[@]}"; do
    echo "$chain_rules" | grep -Fq -- "-s ${src_subnet} -j DROP" || {
      fail "${chain}: DROP rule missing for source subnet ${src_subnet}"
      status=1
    }
  done

  if ! collect_service_ips_for_networks "egress-proxy" proxy_source_ips "${egress_network}"; then
    fail "${chain}: unable to resolve egress-proxy IP on '${egress_network}'"
    status=1
  fi
  if ! collect_service_ips_for_networks "egress-proxy" proxy_dest_ips "${AGENTIC_NETWORK:-agentic}" "${egress_network}"; then
    fail "${chain}: unable to resolve egress-proxy destination IPs"
    status=1
  fi
  if ! collect_service_ips_for_networks "unbound" unbound_source_ips "${egress_network}"; then
    fail "${chain}: unable to resolve unbound IP on '${egress_network}'"
    status=1
  fi
  if ! collect_service_ips_for_networks "unbound" unbound_dest_ips "${AGENTIC_NETWORK:-agentic}" "${egress_network}"; then
    fail "${chain}: unable to resolve unbound destination IPs"
    status=1
  fi
  if ! collect_service_ips_for_networks "ollama" ollama_source_ips "${egress_network}"; then
    fail "${chain}: unable to resolve ollama IP on '${egress_network}'"
    status=1
  fi

  local proxy_ip
  for proxy_ip in "${proxy_source_ips[@]}"; do
    echo "$chain_rules" | grep -Fq -- "-s ${proxy_ip}/32 -p tcp --dport 80 -j ACCEPT" || {
      fail "${chain}: egress-proxy upstream allow missing for ${proxy_ip}:80"
      status=1
    }
    echo "$chain_rules" | grep -Fq -- "-s ${proxy_ip}/32 -p tcp --dport 443 -j ACCEPT" || {
      fail "${chain}: egress-proxy upstream allow missing for ${proxy_ip}:443"
      status=1
    }
  done

  local unbound_ip
  for unbound_ip in "${unbound_source_ips[@]}"; do
    echo "$chain_rules" | grep -Fq -- "-s ${unbound_ip}/32 -p udp --dport 53 -j ACCEPT" || {
      fail "${chain}: unbound UDP allow missing for ${unbound_ip}:53"
      status=1
    }
    echo "$chain_rules" | grep -Fq -- "-s ${unbound_ip}/32 -p tcp --dport 53 -j ACCEPT" || {
      fail "${chain}: unbound TCP allow missing for ${unbound_ip}:53"
      status=1
    }
  done

  local ollama_ip
  for ollama_ip in "${ollama_source_ips[@]}"; do
    echo "$chain_rules" | grep -Fq -- "-s ${ollama_ip}/32 -d ${agentic_subnet} -j ACCEPT" || {
      fail "${chain}: ollama internal allow missing for ${ollama_ip} -> ${agentic_subnet}"
      status=1
    }

    for proxy_ip in "${proxy_dest_ips[@]}"; do
      echo "$chain_rules" | grep -Fq -- "-s ${ollama_ip}/32 -d ${proxy_ip}/32 -p tcp --dport 3128 -j ACCEPT" || {
        fail "${chain}: ollama proxy allow missing for ${ollama_ip} -> ${proxy_ip}:3128"
        status=1
      }
    done

    for unbound_ip in "${unbound_dest_ips[@]}"; do
      echo "$chain_rules" | grep -Fq -- "-s ${ollama_ip}/32 -d ${unbound_ip}/32 -p udp --dport 53 -j ACCEPT" || {
        fail "${chain}: ollama unbound UDP allow missing for ${ollama_ip} -> ${unbound_ip}:53"
        status=1
      }
      echo "$chain_rules" | grep -Fq -- "-s ${ollama_ip}/32 -d ${unbound_ip}/32 -p tcp --dport 53 -j ACCEPT" || {
        fail "${chain}: ollama unbound TCP allow missing for ${ollama_ip} -> ${unbound_ip}:53"
        status=1
      }
    done

    echo "$chain_rules" | grep -Fq -- "-s ${ollama_ip}/32 -j DROP" || {
      fail "${chain}: explicit ollama DROP missing for ${ollama_ip}"
      status=1
    }
  done

  [[ "${status}" -eq 0 ]] || return 1

  ok "DOCKER-USER enforcement chain '${chain}' is present for source subnets ${source_subnets[*]}"
}
