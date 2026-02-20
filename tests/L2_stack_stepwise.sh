#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L2 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"
assert_cmd docker

suffix="l2-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"
export AGENTIC_STACK_ALL_TARGETS="agents,optional"

cleanup() {
  AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" stack stop all >/tmp/agent-l2-down.out 2>&1 || true
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

AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" stack start all >/tmp/agent-l2-stack-start.out \
  || fail "agent stack start all failed"

start_agents_line="$(grep -n 'stack step=start target=agents' /tmp/agent-l2-stack-start.out | head -n 1 | cut -d: -f1)"
start_optional_line="$(grep -n 'stack step=start target=optional' /tmp/agent-l2-stack-start.out | head -n 1 | cut -d: -f1)"
[[ -n "${start_agents_line}" && -n "${start_optional_line}" ]] \
  || fail "stack start output must include agents and optional steps"
[[ "${start_agents_line}" -lt "${start_optional_line}" ]] \
  || fail "stack start order must be agents before optional for selected targets"

claude_cid="$(require_service_container agentic-claude)" || exit 1
wait_for_container_ready "${claude_cid}" 90 || fail "agentic-claude did not become ready"
sentinel_cid="$(require_service_container optional-sentinel)" || exit 1
wait_for_container_ready "${sentinel_cid}" 60 || fail "optional-sentinel did not become ready"

AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" stack stop all >/tmp/agent-l2-stack-stop.out \
  || fail "agent stack stop all failed"

stop_optional_line="$(grep -n 'stack step=stop target=optional' /tmp/agent-l2-stack-stop.out | head -n 1 | cut -d: -f1)"
stop_agents_line="$(grep -n 'stack step=stop target=agents' /tmp/agent-l2-stack-stop.out | head -n 1 | cut -d: -f1)"
[[ -n "${stop_optional_line}" && -n "${stop_agents_line}" ]] \
  || fail "stack stop output must include optional and agents steps"
[[ "${stop_optional_line}" -lt "${stop_agents_line}" ]] \
  || fail "stack stop order must be optional before agents for selected targets"

[[ -z "$(service_container_id optional-sentinel)" ]] || fail "optional-sentinel must be stopped after stack stop"
[[ -z "$(service_container_id agentic-claude)" ]] || fail "agentic-claude must be stopped after stack stop"

ok "L2_stack_stepwise passed"
