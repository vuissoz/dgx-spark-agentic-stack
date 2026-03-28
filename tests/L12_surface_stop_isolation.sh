#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L12 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker

suffix="l12-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_LLM_NETWORK="agentic-${suffix}-llm"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"
export AGENTIC_OPTIONAL_MODULES="goose"
export AGENTIC_SKIP_OPTIONAL_GATING=1
export OLLAMA_HOST_PORT="31434"
export OPENWEBUI_HOST_PORT="38080"
export OPENHANDS_HOST_PORT="33000"
export COMFYUI_HOST_PORT="38188"
export OPENCLAW_WEBHOOK_HOST_PORT="38111"
export OPENCLAW_GATEWAY_HOST_PORT="38789"
export OPENCLAW_RELAY_HOST_PORT="38112"

targets=(claude codex opencode vibestral openclaw goose openwebui openhands comfyui)

cleanup() {
  AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" down optional >/tmp/agent-l12-down-optional.out 2>&1 || true
  "${agent_bin}" down ui >/tmp/agent-l12-down-ui.out 2>&1 || true
  "${agent_bin}" down agents >/tmp/agent-l12-down-agents.out 2>&1 || true
  "${agent_bin}" down core >/tmp/agent-l12-down-core.out 2>&1 || true
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

target_services() {
  case "$1" in
    claude) printf '%s\n' "agentic-claude" ;;
    codex) printf '%s\n' "agentic-codex" ;;
    opencode) printf '%s\n' "agentic-opencode" ;;
    vibestral) printf '%s\n' "agentic-vibestral" ;;
    openclaw)
      printf '%s\n' \
        "openclaw" \
        "openclaw-gateway" \
        "openclaw-provider-bridge" \
        "openclaw-sandbox" \
        "openclaw-relay"
      ;;
    goose) printf '%s\n' "optional-goose" ;;
    openwebui) printf '%s\n' "openwebui" ;;
    openhands) printf '%s\n' "openhands" ;;
    comfyui)
      printf '%s\n' \
        "comfyui" \
        "comfyui-loopback"
      ;;
    *) return 1 ;;
  esac
}

service_container_any_id() {
  local service="$1"
  docker ps -a \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}' | head -n 1
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

all_services=(
  ollama
  ollama-gate
  gate-mcp
  egress-proxy
  unbound
  agentic-claude
  agentic-codex
  agentic-opencode
  agentic-vibestral
  openclaw
  openclaw-gateway
  openclaw-provider-bridge
  openclaw-sandbox
  openclaw-relay
  openwebui
  openhands
  comfyui
  comfyui-loopback
  optional-goose
  optional-sentinel
)

assert_unrelated_services_healthy() {
  local skip_target="$1"
  local -A skipped=()
  local service

  if [[ -n "${skip_target}" ]]; then
    while IFS= read -r service; do
      [[ -n "${service}" ]] || continue
      skipped["${service}"]=1
    done < <(target_services "${skip_target}")
  fi

  for service in "${all_services[@]}"; do
    if [[ -n "${skipped[${service}]:-}" ]]; then
      continue
    fi
    assert_service_healthy_now "${service}" || return 1
  done
}

"${REPO_ROOT}/deployments/bootstrap/init_fs.sh"
"${agent_bin}" up core >/tmp/agent-l12-up-core.out \
  || fail "unable to start core stack for L12"
"${agent_bin}" up agents >/tmp/agent-l12-up-agents.out \
  || fail "unable to start agents stack for L12"
"${agent_bin}" up ui >/tmp/agent-l12-up-ui.out \
  || fail "unable to start ui stack for L12"
AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" up optional >/tmp/agent-l12-up-optional.out \
  || fail "unable to start optional stack for L12"

for service in "${all_services[@]}"; do
  cid="$(require_service_container "${service}")" || exit 1
  wait_for_container_ready "${cid}" 150 || fail "service '${service}' did not become ready"
done

assert_unrelated_services_healthy ""

for target in "${targets[@]}"; do
  "${agent_bin}" stop "${target}" >/tmp/agent-l12-stop-${target}.out \
    || fail "agent stop ${target} failed"
  while IFS= read -r service; do
    [[ -n "${service}" ]] || continue
    assert_service_state "${service}" "exited"
  done < <(target_services "${target}")
  assert_unrelated_services_healthy "${target}"

  "${agent_bin}" start "${target}" >/tmp/agent-l12-start-${target}.out \
    || fail "agent start ${target} failed"
  while IFS= read -r service; do
    [[ -n "${service}" ]] || continue
    wait_for_container_ready "$(require_service_container "${service}")" 150 \
      || fail "service '${service}' did not recover after start ${target}"
  done < <(target_services "${target}")
  assert_unrelated_services_healthy ""
done

ok "L12_surface_stop_isolation passed"
