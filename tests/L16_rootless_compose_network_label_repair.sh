#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L16 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker

suffix="l16-$RANDOM-$$"
base_port="$((24000 + ($$ % 1000) * 20))"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_LLM_NETWORK="agentic-${suffix}-llm"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"
export AGENTIC_SKIP_CORE_IMAGE_BUILD=1
export AGENTIC_OLLAMA_GPU_EXPECTED=0
export GATE_ENABLE_TEST_MODE=1
export OLLAMA_HOST_PORT="$((base_port + 1))"
export OPENCLAW_WEBHOOK_HOST_PORT="$((base_port + 2))"
export OPENCLAW_GATEWAY_HOST_PORT="$((base_port + 3))"
export OPENCLAW_RELAY_HOST_PORT="$((base_port + 4))"
export OPENCLAW_GATEWAY_PROXY_METRICS_PORT="$((base_port + 5))"

cleanup() {
  "${agent_bin}" down core >/tmp/agent-l16-down.out 2>&1 || true
  docker network rm "${AGENTIC_LLM_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_EGRESS_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_NETWORK}" >/dev/null 2>&1 || true
  rm -rf "${AGENTIC_ROOT}"
}
trap cleanup EXIT

assert_network_compose_label() {
  local network_name="$1"
  local expected_network_label="$2"
  local expected_internal="$3"
  local inspect_output

  inspect_output="$(docker network inspect "${network_name}" \
    --format '{{with index .Labels "com.docker.compose.project"}}{{.}}{{end}}|{{with index .Labels "com.docker.compose.network"}}{{.}}{{end}}|{{.Internal}}' 2>/dev/null)" \
    || fail "cannot inspect docker network ${network_name}"
  IFS='|' read -r actual_project actual_network actual_internal <<<"${inspect_output}"

  [[ "${actual_project}" == "${AGENTIC_COMPOSE_PROJECT}" ]] \
    || fail "network ${network_name} has compose project label '${actual_project}', expected '${AGENTIC_COMPOSE_PROJECT}'"
  [[ "${actual_network}" == "${expected_network_label}" ]] \
    || fail "network ${network_name} has compose network label '${actual_network}', expected '${expected_network_label}'"
  [[ "${actual_internal}" == "${expected_internal}" ]] \
    || fail "network ${network_name} has internal='${actual_internal}', expected '${expected_internal}'"
}

docker network create --driver bridge --internal "${AGENTIC_NETWORK}" >/dev/null
docker network create --driver bridge "${AGENTIC_EGRESS_NETWORK}" >/dev/null

if ! "${agent_bin}" up core >/tmp/agent-l16-up.out 2>&1; then
  tail -n 120 /tmp/agent-l16-up.out >&2 || true
  fail "agent up core must repair legacy unlabeled compose networks in rootless-dev"
fi

assert_network_compose_label "${AGENTIC_NETWORK}" "agentic" "true"
assert_network_compose_label "${AGENTIC_LLM_NETWORK}" "agentic-llm" "true"
assert_network_compose_label "${AGENTIC_EGRESS_NETWORK}" "agentic-egress" "false"

toolbox_cid="$(require_service_container toolbox)" || exit 1
wait_for_container_ready "${toolbox_cid}" 60 || fail "toolbox did not become ready after network repair"

ok "L16_rootless_compose_network_label_repair passed"
