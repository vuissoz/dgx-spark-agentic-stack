#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_B_NETWORK_TESTS:-0}" == "1" ]]; then
  ok "B1 skipped because AGENTIC_SKIP_B_NETWORK_TESTS=1"
  exit 0
fi

assert_network_internal "${AGENTIC_NETWORK:-agentic}" || fail "core network must be internal"

ok "B1_network_internal passed"
