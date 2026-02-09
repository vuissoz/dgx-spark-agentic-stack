#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  return 1
}

ok() {
  echo "OK: $*"
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
    done < <(ss -lntH | awk -v p=":${port}" '$4 ~ p"$" { print $4 }')
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
