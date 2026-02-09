#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ -n "${AGENT_TEST_MARKER:-}" ]]; then
  : >"${AGENT_TEST_MARKER}"
fi

ok "A_smoke executed"
