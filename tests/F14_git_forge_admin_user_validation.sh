#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F14 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

set +e
GIT_FORGE_ADMIN_USER=admin "${REPO_ROOT}/agent" profile >/tmp/agent-f14-profile.out 2>&1
rc=$?
set -e

[[ "${rc}" -ne 0 ]] || fail "agent profile must reject reserved git-forge admin usernames"
grep -q "invalid GIT_FORGE_ADMIN_USER='admin'" /tmp/agent-f14-profile.out \
  || fail "agent profile must explain that 'admin' is reserved"

ok "runtime rejects reserved git-forge bootstrap admin usernames"
