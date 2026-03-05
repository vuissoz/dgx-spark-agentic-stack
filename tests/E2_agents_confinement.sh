#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_E_TESTS:-0}" == "1" ]]; then
  ok "E2 skipped because AGENTIC_SKIP_E_TESTS=1"
  exit 0
fi

assert_mount_source() {
  local container_id="$1"
  local destination="$2"
  local expected_source="$3"

  local actual_source
  actual_source="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "'"${destination}"'"}}{{println .Source}}{{end}}{{end}}' "${container_id}" | head -n 1)"
  [[ -n "${actual_source}" ]] || fail "${container_id}: missing mount ${destination}"

  actual_source="$(readlink -f "${actual_source}" 2>/dev/null || printf '%s' "${actual_source}")"
  expected_source="$(readlink -f "${expected_source}" 2>/dev/null || printf '%s' "${expected_source}")"
  [[ "${actual_source}" == "${expected_source}" ]] \
    || fail "${container_id}: mount source mismatch for ${destination} (expected=${expected_source}, actual=${actual_source})"
}

assert_tmux_session() {
  local container_id="$1"
  local session_name="$2"
  timeout 20 docker exec "${container_id}" tmux has-session -t "${session_name}" \
    || fail "${container_id}: tmux session '${session_name}' is missing"
  ok "${container_id}: tmux session '${session_name}' is active"
}

assert_primary_cli() {
  local container_id="$1"
  local cli="$2"
  timeout 20 docker exec "${container_id}" sh -lc "command -v ${cli} >/dev/null" \
    || fail "${container_id}: primary CLI '${cli}' is missing"
  ok "${container_id}: primary CLI '${cli}' is available"
}

assert_ollama_gate_defaults() {
  local container_id="$1"
  local defaults_file="/state/bootstrap/ollama-gate-defaults.env"

  timeout 20 docker exec "${container_id}" sh -lc "test -f '${defaults_file}'" \
    || fail "${container_id}: missing first-run defaults file ${defaults_file}"

  timeout 20 docker exec "${container_id}" sh -lc \
    ". '${defaults_file}'; \
      test \"\${OLLAMA_BASE_URL}\" = 'http://ollama-gate:11435'; \
      test \"\${OPENAI_BASE_URL}\" = 'http://ollama-gate:11435/v1'; \
      test \"\${OPENAI_API_BASE_URL}\" = 'http://ollama-gate:11435/v1'; \
      test \"\${OPENAI_API_BASE}\" = 'http://ollama-gate:11435/v1'; \
      test \"\${OPENAI_API_KEY}\" = 'local-ollama'; \
      test \"\${ANTHROPIC_BASE_URL}\" = 'http://ollama-gate:11435'; \
      test \"\${ANTHROPIC_AUTH_TOKEN}\" = 'local-ollama'; \
      test \"\${ANTHROPIC_API_KEY}\" = 'local-ollama'" \
    || fail "${container_id}: defaults file does not resolve to ollama-gate endpoint"

  ok "${container_id}: first-run LLM defaults target ollama-gate"
}

assert_runtime_gate_routing() {
  local container_id="$1"
  local label="$2"

  timeout 20 docker exec "${container_id}" sh -lc \
    "test \"\${OLLAMA_BASE_URL}\" = 'http://ollama-gate:11435'" \
    || fail "${container_id}: ${label} runtime OLLAMA_BASE_URL must point to ollama-gate"

  timeout 20 docker exec "${container_id}" sh -lc \
    "test \"\${OPENAI_BASE_URL}\" = 'http://ollama-gate:11435/v1'" \
    || fail "${container_id}: ${label} runtime OPENAI_BASE_URL must point to ollama-gate /v1"

  ok "${container_id}: ${label} runtime routes LLM traffic through ollama-gate"
}

assert_write_boundaries() {
  local container_id="$1"

  timeout 20 docker exec "${container_id}" sh -lc \
    'echo e2 >/workspace/.e2_workspace && echo e2 >/state/.e2_state && echo e2 >/logs/.e2_logs' \
    || fail "${container_id}: expected write to workspace/state/logs to succeed"

  timeout 20 docker exec "${container_id}" sh -lc \
    'test -s /workspace/.e2_workspace && test -s /state/.e2_state && test -s /logs/.e2_logs' \
    || fail "${container_id}: write markers missing in writable mounts"

  set +e
  timeout 20 docker exec "${container_id}" sh -lc 'echo deny >/etc/.e2_forbidden' >/dev/null 2>&1
  local write_rc=$?
  set -e

  [[ "${write_rc}" -ne 0 ]] || fail "${container_id}: write outside writable mounts unexpectedly succeeded"
  ok "${container_id}: write boundaries are enforced"
}

assert_agent_sudo_mode_security() {
  local container_id="$1"
  local inspect_out readonly cap_drop security_opt

  inspect_out="$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}|{{join .HostConfig.CapDrop ","}}|{{json .HostConfig.SecurityOpt}}' "${container_id}" 2>/dev/null)" \
    || fail "${container_id}: cannot inspect hardening fields"
  IFS='|' read -r readonly cap_drop security_opt <<<"${inspect_out}"

  [[ "${readonly}" == "true" ]] || fail "${container_id}: readonly rootfs must stay enabled in sudo mode"
  [[ ",${cap_drop}," == *",ALL,"* ]] || fail "${container_id}: cap_drop must include ALL in sudo mode"
  [[ "${security_opt}" == *"no-new-privileges:false"* ]] || fail "${container_id}: sudo mode expects no-new-privileges:false"
  assert_container_non_root_user "${container_id}"
  ok "${container_id}: sudo-mode hardening profile is satisfied"
}

assert_egress_profile() {
  local container_id="$1"

  set +e
  timeout 20 docker exec "${container_id}" sh -lc \
    'env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY curl -fsS --noproxy "*" --max-time 8 https://example.com >/dev/null'
  local direct_rc=$?
  set -e

  [[ "${direct_rc}" -ne 0 ]] || fail "${container_id}: direct egress unexpectedly succeeded"
  ok "${container_id}: direct egress is blocked"

  set +e
  local proxy_output
  proxy_output="$(timeout 20 docker exec "${container_id}" sh -lc 'curl -fsS --max-time 10 -x http://egress-proxy:3128 https://example.com >/dev/null' 2>&1)"
  local proxy_rc=$?
  set -e

  if [[ "${proxy_rc}" -eq 0 ]]; then
    ok "${container_id}: egress via proxy succeeded"
    return 0
  fi

  echo "${proxy_output}" | grep -Eqi 'deny|denied|access denied|ERR_ACCESS_DENIED' \
    || fail "${container_id}: proxy failure is not explicit deny"
  ok "${container_id}: proxy deny is explicit"
}

assert_cmd docker

claude_cid="$(require_service_container agentic-claude)" || exit 1
codex_cid="$(require_service_container agentic-codex)" || exit 1
opencode_cid="$(require_service_container agentic-opencode)" || exit 1
vibestral_cid="$(require_service_container agentic-vibestral)" || exit 1
proxy_cid="$(require_service_container egress-proxy)" || exit 1

wait_for_container_ready "${claude_cid}" 60 || fail "agentic-claude is not ready"
wait_for_container_ready "${codex_cid}" 60 || fail "agentic-codex is not ready"
wait_for_container_ready "${opencode_cid}" 60 || fail "agentic-opencode is not ready"
wait_for_container_ready "${vibestral_cid}" 60 || fail "agentic-vibestral is not ready"
wait_for_container_ready "${proxy_cid}" 60 || fail "egress-proxy is not ready"

assert_tmux_session "${claude_cid}" "claude"
assert_tmux_session "${codex_cid}" "codex"
assert_tmux_session "${opencode_cid}" "opencode"
assert_tmux_session "${vibestral_cid}" "vibestral"

assert_primary_cli "${claude_cid}" "claude"
assert_primary_cli "${codex_cid}" "codex"
assert_primary_cli "${opencode_cid}" "opencode"
assert_primary_cli "${vibestral_cid}" "vibe"

for cid in "${claude_cid}" "${codex_cid}" "${opencode_cid}" "${vibestral_cid}"; do
  if [[ "${AGENTIC_AGENT_NO_NEW_PRIVILEGES:-true}" == "false" ]]; then
    assert_agent_sudo_mode_security "${cid}"
  else
    assert_container_security "${cid}"
  fi
  assert_proxy_enforced "${cid}"
  assert_egress_profile "${cid}"
  assert_ollama_gate_defaults "${cid}"
  assert_write_boundaries "${cid}"
  if [[ "${AGENTIC_AGENT_NO_NEW_PRIVILEGES:-true}" == "false" ]]; then
    timeout 20 docker exec "${cid}" sh -lc 'command -v sudo >/dev/null && sudo -n true' \
      || fail "${cid}: sudo-mode is enabled but sudo -n true failed"
    ok "${cid}: sudo is usable in sudo mode"
  fi
done

assert_runtime_gate_routing "${opencode_cid}" "opencode"
assert_runtime_gate_routing "${vibestral_cid}" "vibestral"

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
agentic_profile="${AGENTIC_PROFILE:-strict-prod}"
if [[ -n "${AGENTIC_AGENT_WORKSPACES_ROOT:-}" ]]; then
  agent_workspaces_root="${AGENTIC_AGENT_WORKSPACES_ROOT}"
elif [[ "${agentic_profile}" == "rootless-dev" ]]; then
  agent_workspaces_root="${agentic_root}/agent-workspaces"
else
  agent_workspaces_root="${agentic_root}"
fi
claude_workspaces_dir="${AGENTIC_CLAUDE_WORKSPACES_DIR:-${agent_workspaces_root}/claude/workspaces}"
codex_workspaces_dir="${AGENTIC_CODEX_WORKSPACES_DIR:-${agent_workspaces_root}/codex/workspaces}"
opencode_workspaces_dir="${AGENTIC_OPENCODE_WORKSPACES_DIR:-${agent_workspaces_root}/opencode/workspaces}"
vibestral_workspaces_dir="${AGENTIC_VIBESTRAL_WORKSPACES_DIR:-${agent_workspaces_root}/vibestral/workspaces}"
assert_mount_source "${claude_cid}" "/state" "${agentic_root}/claude/state"
assert_mount_source "${claude_cid}" "/logs" "${agentic_root}/claude/logs"
assert_mount_source "${claude_cid}" "/workspace" "${claude_workspaces_dir}"
assert_mount_source "${codex_cid}" "/state" "${agentic_root}/codex/state"
assert_mount_source "${codex_cid}" "/logs" "${agentic_root}/codex/logs"
assert_mount_source "${codex_cid}" "/workspace" "${codex_workspaces_dir}"
assert_mount_source "${opencode_cid}" "/state" "${agentic_root}/opencode/state"
assert_mount_source "${opencode_cid}" "/logs" "${agentic_root}/opencode/logs"
assert_mount_source "${opencode_cid}" "/workspace" "${opencode_workspaces_dir}"
assert_mount_source "${vibestral_cid}" "/state" "${agentic_root}/vibestral/state"
assert_mount_source "${vibestral_cid}" "/logs" "${agentic_root}/vibestral/logs"
assert_mount_source "${vibestral_cid}" "/workspace" "${vibestral_workspaces_dir}"
ok "agents volumes map to ${agentic_root}/<tool>/{state,logs} and dedicated workspace host paths"

ok "E2_agents_confinement passed"
