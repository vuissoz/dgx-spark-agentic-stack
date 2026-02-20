#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L3 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"
assert_cmd docker

suffix="l3-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"
export AGENTIC_STACK_ALL_TARGETS="optional"
export AGENTIC_CLEANUP_EXPORT_DIR="${REPO_ROOT}/.runtime/${suffix}-exports"

cleanup() {
  AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" down optional >/tmp/agent-l3-down.out 2>&1 || true
  docker network rm "${AGENTIC_EGRESS_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_NETWORK}" >/dev/null 2>&1 || true
  if [[ -d "${AGENTIC_ROOT}" ]]; then
    find "${AGENTIC_ROOT}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${AGENTIC_ROOT}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
  fi
  if [[ -d "${AGENTIC_CLEANUP_EXPORT_DIR}" ]]; then
    find "${AGENTIC_CLEANUP_EXPORT_DIR}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${AGENTIC_CLEANUP_EXPORT_DIR}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${AGENTIC_CLEANUP_EXPORT_DIR}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

docker network create --driver bridge --internal "${AGENTIC_NETWORK}" >/dev/null
docker network create --driver bridge "${AGENTIC_EGRESS_NETWORK}" >/dev/null

"${REPO_ROOT}/deployments/bootstrap/init_fs.sh"
AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" up optional >/tmp/agent-l3-up.out \
  || fail "unable to start optional stack for cleanup test"

sentinel_cid="$(require_service_container optional-sentinel)" || exit 1
wait_for_container_ready "${sentinel_cid}" 60 || fail "optional-sentinel did not become ready"

touch "${AGENTIC_ROOT}/cleanup-marker.txt"
mkdir -p "${AGENTIC_ROOT}/nested/state"
touch "${AGENTIC_ROOT}/nested/state/value.txt"

printf 'y\nCLEAN\n' | "${agent_bin}" cleanup >/tmp/agent-l3-cleanup.out \
  || fail "agent cleanup interactive flow failed"

grep -q 'cleanup completed root=' /tmp/agent-l3-cleanup.out \
  || fail "cleanup output must include completion marker"

[[ -d "${AGENTIC_ROOT}" ]] || fail "cleanup must preserve runtime root directory"
if find "${AGENTIC_ROOT}" -mindepth 1 -print -quit | grep -q .; then
  fail "cleanup must remove all files under runtime root"
fi

backup_count="$(find "${AGENTIC_CLEANUP_EXPORT_DIR}" -maxdepth 1 -type f -name '*.tar.gz' | wc -l | tr -d ' ')"
[[ "${backup_count}" -ge 1 ]] || fail "cleanup must export a backup archive when backup is requested"

[[ -z "$(service_container_id optional-sentinel)" ]] || fail "optional-sentinel must be stopped by cleanup"

ok "L3_cleanup passed"
