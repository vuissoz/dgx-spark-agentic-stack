#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L4 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"
assert_cmd docker

suffix="l4-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"
export AGENTIC_STACK_ALL_TARGETS="optional"

cleanup() {
  chmod -R u+rwx "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
  rm -rf "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${REPO_ROOT}/deployments/bootstrap/init_fs.sh"

mkdir -p "${AGENTIC_ROOT}/permission-denied/subtree"
touch "${AGENTIC_ROOT}/permission-denied/subtree/payload.txt"
chmod 000 "${AGENTIC_ROOT}/permission-denied/subtree"
chmod 000 "${AGENTIC_ROOT}/permission-denied"

"${agent_bin}" rootless-dev cleanup --yes --no-backup >/tmp/agent-l4-cleanup.out 2>&1 \
  || fail "agent rootless-dev cleanup --yes --no-backup failed on permission-denied runtime tree"

grep -q 'cleanup: direct purge failed under rootless-dev, attempting docker helper fallback' /tmp/agent-l4-cleanup.out \
  || fail "cleanup did not report docker helper fallback after permission denial"
grep -q 'cleanup completed root=' /tmp/agent-l4-cleanup.out \
  || fail "cleanup output must include completion marker"

[[ -d "${AGENTIC_ROOT}" ]] || fail "cleanup must preserve runtime root directory"
if find "${AGENTIC_ROOT}" -mindepth 1 -print -quit | grep -q .; then
  fail "cleanup must remove all files under runtime root after helper fallback"
fi

ok "L4_cleanup_permission_denied_fallback passed"
