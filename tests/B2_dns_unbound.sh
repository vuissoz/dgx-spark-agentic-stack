#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_B_NETWORK_TESTS:-0}" == "1" ]]; then
  ok "B2 skipped because AGENTIC_SKIP_B_NETWORK_TESTS=1"
  exit 0
fi

toolbox_cid="$(require_service_container toolbox)"
unbound_cid="$(require_service_container unbound)"

wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${unbound_cid}" 45 || fail "unbound is not ready"

if docker exec "${toolbox_cid}" sh -lc 'command -v drill >/dev/null 2>&1'; then
  timeout 12 docker exec "${toolbox_cid}" sh -lc 'drill @unbound example.com | grep -q "ANSWER SECTION"' \
    || fail "DNS query through unbound failed from toolbox"
  ok "toolbox resolves example.com through unbound (drill)"

  set +e
  timeout 10 docker exec "${toolbox_cid}" sh -lc 'drill @1.1.1.1 example.com >/dev/null 2>&1'
  direct_rc=$?
  set -e
else
  timeout 12 docker exec "${toolbox_cid}" sh -lc 'dig @unbound example.com +short | grep -Eq "^[0-9]"' \
    || fail "DNS query through unbound failed from toolbox"
  ok "toolbox resolves example.com through unbound (dig)"

  set +e
  timeout 10 docker exec "${toolbox_cid}" sh -lc 'dig @1.1.1.1 example.com +time=2 +tries=1 >/dev/null 2>&1'
  direct_rc=$?
  set -e
fi

if [[ "$direct_rc" -eq 0 ]]; then
  fail "direct DNS query to 1.1.1.1 succeeded (expected blocked path via DOCKER-USER)"
fi
ok "direct DNS query to 1.1.1.1 is blocked"

ok "B2_dns_unbound passed"
