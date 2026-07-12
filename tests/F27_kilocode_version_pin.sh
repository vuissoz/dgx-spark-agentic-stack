#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

pin='@kilocode/cli@7.4.5'

for file in \
  "${REPO_ROOT}/compose/compose.agents.yml" \
  "${REPO_ROOT}/deployments/images/agent-cli-base/Dockerfile" \
  "${REPO_ROOT}/deployments/images/agent-cli-base/install-agent-clis.sh" \
  "${REPO_ROOT}/scripts/lib/runtime.sh"; do
  rg -qF "${pin}" "${file}" || fail "Kilocode default is not pinned in ${file}"
  ! rg -qF '@kilocode/cli@latest' "${file}" || fail "Kilocode must not default to mutable latest in ${file}"
done

rg -qF "${pin}" "${REPO_ROOT}/docs/decisions/ADR-0113-kilocode-first-class-agent.md" \
  || fail "ADR-0113 must document the Kilocode pin"
ok "Kilocode CLI default is version pinned across build and runtime paths"
