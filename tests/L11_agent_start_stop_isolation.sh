#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L11 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker

suffix="l11-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_LLM_NETWORK="agentic-${suffix}-llm"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"
export OLLAMA_HOST_PORT="21434"
export OPENCLAW_WEBHOOK_HOST_PORT="28111"
export OPENCLAW_GATEWAY_HOST_PORT="28789"
export OPENCLAW_RELAY_HOST_PORT="28112"
export AGENTIC_DOCTOR_CRITICAL_PORTS="${OLLAMA_HOST_PORT},${OPENCLAW_WEBHOOK_HOST_PORT},${OPENCLAW_GATEWAY_HOST_PORT},${OPENCLAW_RELAY_HOST_PORT}"
export AGENTIC_DOCTOR_DEFAULT_MODEL_TIMEOUT_SEC=10
export GATE_ENABLE_TEST_MODE=1

agent_services=(agentic-claude agentic-codex agentic-opencode agentic-kilocode agentic-vibestral agentic-hermes)
core_services=(ollama ollama-gate gate-mcp egress-proxy unbound)

cleanup() {
  "${agent_bin}" down agents >/tmp/agent-l11-down-agents.out 2>&1 || true
  "${agent_bin}" down core >/tmp/agent-l11-down-core.out 2>&1 || true
  docker network rm "${AGENTIC_LLM_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_EGRESS_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_NETWORK}" >/dev/null 2>&1 || true
  if [[ -d "${AGENTIC_ROOT}" ]]; then
    find "${AGENTIC_ROOT}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${AGENTIC_ROOT}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

service_container_any_id() {
  local service="$1"
  docker ps -a \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}' | head -n 1
}

service_container_name_any() {
  local service="$1"
  docker ps -a \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.Names}}' | head -n 1
}

assert_service_state() {
  local service="$1"
  local expected_state="$2"
  local cid state

  cid="$(service_container_any_id "${service}")"
  [[ -n "${cid}" ]] || fail "service '${service}' container is missing"
  state="$(docker inspect --format '{{.State.Status}}' "${cid}")"
  [[ "${state}" == "${expected_state}" ]] \
    || fail "service '${service}' state mismatch (expected=${expected_state}, actual=${state})"
}

assert_service_healthy_now() {
  local service="$1"
  local cid state health

  cid="$(service_container_any_id "${service}")"
  [[ -n "${cid}" ]] || fail "service '${service}' container is missing"
  state="$(docker inspect --format '{{.State.Status}}' "${cid}")"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}")"
  [[ "${state}" == "running" ]] || fail "service '${service}' is not running (state=${state})"
  [[ "${health}" == "healthy" ]] || fail "service '${service}' is not healthy (health=${health})"
}

assert_unrelated_services_healthy() {
  local skipped_service="$1"
  local service

  for service in "${core_services[@]}" "${agent_services[@]}"; do
    [[ "${service}" == "${skipped_service}" ]] && continue
    assert_service_healthy_now "${service}" || return 1
  done
}

assert_ls_status() {
  local tool="$1"
  local expected_status="$2"
  local expected_tmux="$3"
  local line

  line="$("${agent_bin}" ls | awk -F '\t' -v tool="${tool}" '$1 == tool { print $0 }')"
  [[ -n "${line}" ]] || fail "agent ls is missing row for ${tool}"
  [[ "$(printf '%s\n' "${line}" | awk -F '\t' '{print $3}')" == "${expected_status}" ]] \
    || fail "agent ls status mismatch for ${tool} (expected=${expected_status})"
  [[ "$(printf '%s\n' "${line}" | awk -F '\t' '{print $4}')" == "${expected_tmux}" ]] \
    || fail "agent ls tmux mismatch for ${tool} (expected=${expected_tmux})"
}

prepare_agent_session() {
  local tool="$1"
  local service="$2"
  local project_name="l11-${tool}-${RANDOM}"
  local cid path

  AGENT_NO_ATTACH=1 AGENT_PROJECT_NAME="${project_name}" "${agent_bin}" "${tool}" >/tmp/agent-l11-${tool}.out \
    || fail "agent ${tool} prepare failed after restart"

  cid="$(require_service_container "${service}")" || exit 1
  timeout 20 docker exec "${cid}" tmux has-session -t "${tool}" \
    || fail "tmux session '${tool}' missing after restart for ${service}"
  path="$(timeout 20 docker exec "${cid}" tmux display-message -p -t "${tool}" '#{pane_current_path}')"
  [[ "${path}" == "/workspace/${project_name}" ]] \
    || fail "agent ${tool} pane path mismatch after restart (expected=/workspace/${project_name}, actual=${path})"
}

"${REPO_ROOT}/deployments/bootstrap/init_fs.sh"
"${agent_bin}" up core >/tmp/agent-l11-up-core.out \
  || fail "unable to start core stack for L11"
"${agent_bin}" up agents >/tmp/agent-l11-up-agents.out \
  || fail "unable to start agents stack for L11"

for service in "${core_services[@]}" "${agent_services[@]}"; do
  cid="$(require_service_container "${service}")" || exit 1
  wait_for_container_ready "${cid}" 120 || fail "service '${service}' did not become ready"
done

for tool in claude codex opencode kilocode vibestral hermes; do
  prepare_agent_session "${tool}" "agentic-${tool}"
done

assert_unrelated_services_healthy ""

"${agent_bin}" stop claude >/tmp/agent-l11-stop-claude.out \
  || fail "agent stop claude failed"
assert_service_state "agentic-claude" "exited"
assert_unrelated_services_healthy "agentic-claude"
assert_ls_status "claude" "down" "-"
"${agent_bin}" start service agentic-claude >/tmp/agent-l11-start-claude.out \
  || fail "agent start service agentic-claude failed"
wait_for_container_ready "$(require_service_container agentic-claude)" 90 || fail "agentic-claude did not recover after restart"
assert_unrelated_services_healthy ""
assert_ls_status "claude" "running" "up"
prepare_agent_session "claude" "agentic-claude"

"${agent_bin}" stop service agentic-codex >/tmp/agent-l11-stop-codex.out \
  || fail "agent stop service agentic-codex failed"
assert_service_state "agentic-codex" "exited"
assert_unrelated_services_healthy "agentic-codex"
assert_ls_status "codex" "down" "-"
"${agent_bin}" start service agentic-codex >/tmp/agent-l11-start-codex.out \
  || fail "agent start service agentic-codex failed"
wait_for_container_ready "$(require_service_container agentic-codex)" 90 || fail "agentic-codex did not recover after restart"
assert_unrelated_services_healthy ""
assert_ls_status "codex" "running" "up"
prepare_agent_session "codex" "agentic-codex"

opencode_name="$(service_container_name_any agentic-opencode)"
[[ -n "${opencode_name}" ]] || fail "unable to resolve agentic-opencode container name"
"${agent_bin}" stop container "${opencode_name}" >/tmp/agent-l11-stop-opencode.out \
  || fail "agent stop container ${opencode_name} failed"
assert_service_state "agentic-opencode" "exited"
assert_unrelated_services_healthy "agentic-opencode"
assert_ls_status "opencode" "down" "-"
"${agent_bin}" start container "${opencode_name}" >/tmp/agent-l11-start-opencode.out \
  || fail "agent start container ${opencode_name} failed"
wait_for_container_ready "$(require_service_container agentic-opencode)" 90 || fail "agentic-opencode did not recover after restart"
assert_unrelated_services_healthy ""
assert_ls_status "opencode" "running" "up"
prepare_agent_session "opencode" "agentic-opencode"

"${agent_bin}" stop kilocode >/tmp/agent-l11-stop-kilocode.out \
  || fail "agent stop kilocode failed"
assert_service_state "agentic-kilocode" "exited"
assert_unrelated_services_healthy "agentic-kilocode"
assert_ls_status "kilocode" "down" "-"
"${agent_bin}" start service agentic-kilocode >/tmp/agent-l11-start-kilocode.out \
  || fail "agent start service agentic-kilocode failed"
wait_for_container_ready "$(require_service_container agentic-kilocode)" 90 || fail "agentic-kilocode did not recover after restart"
assert_unrelated_services_healthy ""
assert_ls_status "kilocode" "running" "up"
prepare_agent_session "kilocode" "agentic-kilocode"

"${agent_bin}" stop vibestral >/tmp/agent-l11-stop-vibestral.out \
  || fail "agent stop vibestral failed"
assert_service_state "agentic-vibestral" "exited"
assert_unrelated_services_healthy "agentic-vibestral"
assert_ls_status "vibestral" "down" "-"
"${agent_bin}" start service agentic-vibestral >/tmp/agent-l11-start-vibestral.out \
  || fail "agent start service agentic-vibestral failed"
wait_for_container_ready "$(require_service_container agentic-vibestral)" 90 || fail "agentic-vibestral did not recover after restart"
assert_unrelated_services_healthy ""
assert_ls_status "vibestral" "running" "up"
prepare_agent_session "vibestral" "agentic-vibestral"

"${agent_bin}" stop hermes >/tmp/agent-l11-stop-hermes.out \
  || fail "agent stop hermes failed"
assert_service_state "agentic-hermes" "exited"
assert_unrelated_services_healthy "agentic-hermes"
assert_ls_status "hermes" "down" "-"
"${agent_bin}" start service agentic-hermes >/tmp/agent-l11-start-hermes.out \
  || fail "agent start service agentic-hermes failed"
wait_for_container_ready "$(require_service_container agentic-hermes)" 90 || fail "agentic-hermes did not recover after restart"
assert_unrelated_services_healthy ""
assert_ls_status "hermes" "running" "up"
prepare_agent_session "hermes" "agentic-hermes"

ok "L11_agent_start_stop_isolation passed"
