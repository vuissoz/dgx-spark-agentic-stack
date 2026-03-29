#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_B_NETWORK_TESTS:-0}" == "1" ]]; then
  ok "B4 skipped because AGENTIC_SKIP_B_NETWORK_TESTS=1"
  exit 0
fi

if [[ "${AGENTIC_PROFILE:-strict-prod}" == "rootless-dev" ]]; then
  ok "B4 skipped in rootless-dev profile (no host DOCKER-USER enforcement expected)"
  exit 0
fi

assert_docker_user_policy || fail "DOCKER-USER enforcement policy not in place"

toolbox_cid="$(require_service_container toolbox)"
proxy_cid="$(require_service_container egress-proxy)"
ollama_cid="$(require_service_container ollama)"
chain="${AGENTIC_DOCKER_USER_CHAIN:-AGENTIC-DOCKER-USER}"
proxy_ip="$(docker inspect --format '{{with index .NetworkSettings.Networks "'"${AGENTIC_NETWORK:-agentic}"'"}}{{.IPAddress}}{{end}}' "${proxy_cid}")"
[[ -n "${proxy_ip}" ]] || fail "cannot resolve egress-proxy IP on network ${AGENTIC_NETWORK:-agentic}"

before_drop_count="$(iptables -nvL "${chain}" 2>/dev/null | awk '$3=="DROP" {print $1; exit}')"
before_drop_count="${before_drop_count:-0}"

set +e
timeout 12 docker exec "${toolbox_cid}" sh -lc 'curl -fsS --max-time 6 http://1.1.1.1 >/dev/null'
blocked_rc=$?
set -e

if [[ "$blocked_rc" -eq 0 ]]; then
  fail "direct egress bypass succeeded; expected DOCKER-USER drop"
fi
ok "direct egress bypass attempt is blocked"

after_drop_count="$(iptables -nvL "${chain}" 2>/dev/null | awk '$3=="DROP" {print $1; exit}')"
after_drop_count="${after_drop_count:-0}"

if (( after_drop_count <= before_drop_count )); then
  warn "DROP counter unchanged after direct internet probe; forcing deterministic blocked flow via egress-proxy:80"
  set +e
  timeout 12 docker exec "${toolbox_cid}" sh -lc "curl -fsS --max-time 6 http://${proxy_ip}:80 >/dev/null"
  blocked_proxy_rc=$?
  set -e
  if [[ "$blocked_proxy_rc" -eq 0 ]]; then
    fail "unexpected success reaching egress-proxy on blocked port 80"
  fi
  after_drop_count="$(iptables -nvL "${chain}" 2>/dev/null | awk '$3=="DROP" {print $1; exit}')"
  after_drop_count="${after_drop_count:-0}"
fi

if (( after_drop_count <= before_drop_count )); then
  set +e
  docker exec "${toolbox_cid}" sh -lc 'ip route | grep -q "^default "'
  has_default_route_rc=$?
  set -e
  if [[ "${has_default_route_rc}" -ne 0 ]]; then
    warn "DROP counter unchanged because toolbox has no default route (internal network blocks egress before FORWARD/DOCKER-USER)"
    ok "egress bypass is still blocked and DOCKER-USER policy is present"
    ok "B4_docker_user_enforced passed (pre-forward block mode)"
    exit 0
  fi
  fail "DOCKER-USER drop counter did not increase (before=${before_drop_count}, after=${after_drop_count})"
fi
ok "DOCKER-USER drop counter increased after blocked attempt (before=${before_drop_count}, after=${after_drop_count})"

timeout 12 docker exec "${ollama_cid}" bash -lc 'exec 3<>/dev/tcp/egress-proxy/3128' \
  || fail "ollama cannot reach egress-proxy:3128 despite explicit allow rule"
ok "ollama can reach egress-proxy:3128"

set +e
timeout 12 docker exec "${ollama_cid}" bash -lc 'exec 3<>/dev/tcp/1.1.1.1/80'
ollama_direct_rc=$?
set -e

if [[ "${ollama_direct_rc}" -eq 0 ]]; then
  fail "ollama direct egress bypass succeeded; expected explicit DOCKER-USER drop"
fi
ok "ollama direct egress bypass attempt is blocked"

ok "B4_docker_user_enforced passed"
