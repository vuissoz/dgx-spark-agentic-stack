#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L1 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"
assert_cmd docker

suffix="l1-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"

cleanup() {
  AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" down optional >/tmp/agent-l1-down.out 2>&1 || true
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

"${REPO_ROOT}/deployments/bootstrap/init_fs.sh"
AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" up optional >/tmp/agent-l1-up.out \
  || fail "unable to start optional stack for L1"

sentinel_cid="$(require_service_container optional-sentinel)" || exit 1
wait_for_container_ready "${sentinel_cid}" 60 || fail "optional-sentinel did not become ready"

"${agent_bin}" stop service optional-sentinel >/tmp/agent-l1-stop-service.out \
  || fail "agent stop service optional-sentinel failed"
service_state="$(docker inspect --format '{{.State.Status}}' "${sentinel_cid}")"
[[ "${service_state}" == "exited" ]] || fail "optional-sentinel should be exited after service stop (state=${service_state})"

"${agent_bin}" start service optional-sentinel >/tmp/agent-l1-start-service.out \
  || fail "agent start service optional-sentinel failed"
service_state="$(docker inspect --format '{{.State.Status}}' "${sentinel_cid}")"
[[ "${service_state}" == "running" ]] || fail "optional-sentinel should be running after service start (state=${service_state})"

sentinel_name="$(docker ps -a \
  --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
  --filter "label=com.docker.compose.service=optional-sentinel" \
  --format '{{.Names}}' | head -n 1)"
[[ -n "${sentinel_name}" ]] || fail "unable to resolve optional-sentinel container name"

"${agent_bin}" stop container "${sentinel_name}" >/tmp/agent-l1-stop-container.out \
  || fail "agent stop container failed"
container_state="$(docker inspect --format '{{.State.Status}}' "${sentinel_name}")"
[[ "${container_state}" == "exited" ]] || fail "container should be exited after container stop (state=${container_state})"

"${agent_bin}" start container "${sentinel_name}" >/tmp/agent-l1-start-container.out \
  || fail "agent start container failed"
container_state="$(docker inspect --format '{{.State.Status}}' "${sentinel_name}")"
[[ "${container_state}" == "running" ]] || fail "container should be running after container start (state=${container_state})"

ok "L1_stop_resources passed"
