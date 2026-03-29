#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F5 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"
assert_cmd docker

suffix="f5-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"

cleanup() {
  AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" down optional >/tmp/agent-f5-down.out 2>&1 || true
  docker network rm "${AGENTIC_EGRESS_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_NETWORK}" >/dev/null 2>&1 || true
  if [[ -d "${AGENTIC_ROOT}" ]]; then
    find "${AGENTIC_ROOT}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${AGENTIC_ROOT}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

docker network create --driver bridge --internal "${AGENTIC_NETWORK}" >/dev/null
docker network create --driver bridge "${AGENTIC_EGRESS_NETWORK}" >/dev/null

"${REPO_ROOT}/deployments/bootstrap/init_fs.sh" >/tmp/agent-f5-initfs.out

"${agent_bin}" up core >/tmp/agent-f5-up-core.out \
  || fail "agent up core failed in F5"
AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" up optional >/tmp/agent-f5-up-optional.out \
  || fail "agent up optional failed in F5"

auto_snapshot_line_count="$(
  (
    grep -c '^auto snapshot created release=' /tmp/agent-f5-up-core.out || true
    grep -c '^auto snapshot created release=' /tmp/agent-f5-up-optional.out || true
  ) | awk '{sum += $1} END {print sum + 0}'
)"
[[ "${auto_snapshot_line_count}" -ge 2 ]] \
  || fail "sequential agent up runs should refresh the automatic release snapshot"

release_images="${AGENTIC_ROOT}/deployments/current/images.json"
[[ -s "${release_images}" ]] || fail "automatic release snapshot must create ${release_images}"
release_compose_files="${AGENTIC_ROOT}/deployments/current/compose.files"
release_latest_resolution="${AGENTIC_ROOT}/deployments/current/latest-resolution.json"

[[ -s "${release_compose_files}" ]] || fail "automatic release snapshot must record compose.files"
[[ -s "${release_latest_resolution}" ]] || fail "automatic release snapshot must record latest-resolution.json"

grep -q 'optional-sentinel' "${release_images}" \
  || fail "automatic release snapshot must include running optional-sentinel service"
grep -q '/compose\.core\.yml$' "${release_compose_files}" \
  || fail "automatic release snapshot must retain compose.core.yml after a later up"
grep -q '/compose\.optional\.yml$' "${release_compose_files}" \
  || fail "automatic release snapshot must include compose.optional.yml after optional up"

ok "F5_auto_release_manifest passed"
