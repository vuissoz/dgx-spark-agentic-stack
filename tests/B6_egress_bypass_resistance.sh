#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_B_NETWORK_TESTS:-0}" == "1" ]]; then
  ok "B6 skipped because AGENTIC_SKIP_B_NETWORK_TESTS=1"
  exit 0
fi

pick_agent_service() {
  local service
  for service in agentic-codex agentic-claude agentic-opencode agentic-kilocode agentic-vibestral agentic-hermes; do
    if service_container_id "${service}" >/dev/null 2>&1 && [[ -n "$(service_container_id "${service}")" ]]; then
      printf '%s\n' "${service}"
      return 0
    fi
  done
  return 1
}

docker_user_drop_counter() {
  local chain="${AGENTIC_DOCKER_USER_CHAIN:-AGENTIC-DOCKER-USER}"
  iptables -nvL "${chain}" 2>/dev/null | awk '$3=="DROP" {print $1; exit}'
}

run_direct_probe_expect_blocked() {
  local container_id="$1"
  local label="$2"
  local command="$3"
  local output=""
  local rc=0

  set +e
  output="$(timeout 20 docker exec "${container_id}" sh -lc "${command}" 2>&1)"
  rc=$?
  set -e

  [[ "${rc}" -ne 0 ]] || fail "${label}: direct egress bypass unexpectedly succeeded"
  ok "${label}: direct egress bypass is blocked"
}

assert_proxy_path_allowlisted() {
  local container_id="$1"
  local label="$2"

  timeout 20 docker exec "${container_id}" sh -lc \
    'curl -fsS --max-time 10 -x http://egress-proxy:3128 https://example.com >/dev/null' \
    || fail "${label}: allowlisted proxy path to example.com failed"
  ok "${label}: allowlisted proxy path succeeds"
}

assert_proxy_access_logged() {
  local proxy_log="${AGENTIC_ROOT:-/srv/agentic}/proxy/logs/access.log"
  [[ -s "${proxy_log}" ]] || fail "proxy access log is missing or empty: ${proxy_log}"
  grep -Fq "example.com" "${proxy_log}" || fail "proxy access log does not contain example.com traffic proof"
  ok "proxy access log contains example.com traffic proof"
}

assert_cmd docker

agent_service="$(pick_agent_service)" || fail "no managed agent container is running"
agent_cid="$(require_service_container "${agent_service}")" || exit 1
proxy_cid="$(require_service_container egress-proxy)" || exit 1

wait_for_container_ready "${agent_cid}" 90 || fail "${agent_service} is not ready"
wait_for_container_ready "${proxy_cid}" 60 || fail "egress-proxy is not ready"

assert_proxy_enforced "${agent_cid}"

if [[ "${AGENTIC_PROFILE:-strict-prod}" != "rootless-dev" ]]; then
  assert_docker_user_policy || fail "DOCKER-USER enforcement policy not in place"
  before_drop_count="$(docker_user_drop_counter)"
  before_drop_count="${before_drop_count:-0}"
else
  before_drop_count=""
  ok "B6 host-level DOCKER-USER assertions skipped in rootless-dev"
fi

run_direct_probe_expect_blocked \
  "${agent_cid}" \
  "${agent_service}: env-unset https://example.com" \
  'env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY curl -fsS --noproxy "*" --max-time 8 https://example.com >/dev/null'

run_direct_probe_expect_blocked \
  "${agent_cid}" \
  "${agent_service}: NO_PROXY=* https://example.com" \
  'NO_PROXY="*" no_proxy="*" ALL_PROXY="" all_proxy="" HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" curl -fsS --max-time 8 https://example.com >/dev/null'

run_direct_probe_expect_blocked \
  "${agent_cid}" \
  "${agent_service}: env-unset http://1.1.1.1" \
  'env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY curl -fsS --noproxy "*" --max-time 8 http://1.1.1.1 >/dev/null'

assert_proxy_path_allowlisted "${agent_cid}" "${agent_service}"
assert_proxy_access_logged

if [[ "${AGENTIC_PROFILE:-strict-prod}" != "rootless-dev" ]]; then
  after_drop_count="$(docker_user_drop_counter)"
  after_drop_count="${after_drop_count:-0}"
  if (( after_drop_count <= before_drop_count )); then
    fail "DOCKER-USER drop counter did not increase after agent bypass attempts (before=${before_drop_count}, after=${after_drop_count})"
  fi
  ok "DOCKER-USER drop counter increased after agent bypass attempts (before=${before_drop_count}, after=${after_drop_count})"
fi

ok "B6_egress_bypass_resistance passed"
