#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_B_NETWORK_TESTS:-0}" == "1" ]]; then
  ok "B4 skipped because AGENTIC_SKIP_B_NETWORK_TESTS=1"
  exit 0
fi

assert_docker_user_policy || fail "DOCKER-USER enforcement policy not in place"

toolbox_cid="$(require_service_container toolbox)"
chain="${AGENTIC_DOCKER_USER_CHAIN:-AGENTIC-DOCKER-USER}"

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
  fail "DOCKER-USER drop counter did not increase (before=${before_drop_count}, after=${after_drop_count})"
fi
ok "DOCKER-USER drop counter increased after blocked attempt"

ok "B4_docker_user_enforced passed"
