#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_B_NETWORK_TESTS:-0}" == "1" ]]; then
  ok "B3 skipped because AGENTIC_SKIP_B_NETWORK_TESTS=1"
  exit 0
fi

toolbox_cid="$(require_service_container toolbox)"
proxy_cid="$(require_service_container egress-proxy)"

wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${proxy_cid}" 60 || fail "egress-proxy is not ready"

set +e
timeout 15 docker exec "${toolbox_cid}" sh -lc 'curl -fsS --max-time 8 https://example.com >/dev/null'
direct_rc=$?
set -e

if [[ "$direct_rc" -eq 0 ]]; then
  fail "direct egress from toolbox succeeded without proxy"
fi
ok "direct egress from toolbox is blocked"

set +e
proxy_output="$(timeout 15 docker exec "${toolbox_cid}" sh -lc 'curl -fsS --max-time 10 -x http://egress-proxy:3128 https://example.com >/dev/null' 2>&1)"
proxy_rc=$?
set -e

if [[ "$proxy_rc" -eq 0 ]]; then
  ok "egress via proxy succeeded for allowlisted domain"
else
  echo "$proxy_output" | grep -Eqi 'deny|denied|access denied|ERR_ACCESS_DENIED' \
    || fail "proxy request failed without explicit deny message"
  ok "proxy deny is explicit in output"
fi

proxy_log="${AGENTIC_ROOT:-/srv/agentic}/proxy/logs/access.log"
[[ -s "$proxy_log" ]] || fail "proxy access log is missing or empty: ${proxy_log}"
ok "proxy logs are present at ${proxy_log}"

ok "B3_proxy_policy passed"
