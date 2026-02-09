#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_PORT_BIND_CHECK:-0}" == "1" ]]; then
  ok "A3 skipped because AGENTIC_SKIP_PORT_BIND_CHECK=1"
  exit 0
fi

if [[ -n "${AGENTIC_CRITICAL_PORTS:-}" ]]; then
  # shellcheck disable=SC2206
  ports=(${AGENTIC_CRITICAL_PORTS})
  assert_no_public_bind "${ports[@]}" || fail "public bind detected on critical port list: ${AGENTIC_CRITICAL_PORTS}"
else
  assert_no_public_bind || fail "public bind detected on default critical ports"
fi

ok "A3_no_public_bind passed"
