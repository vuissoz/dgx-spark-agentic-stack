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
  assert_container_security "${cid}"
  assert_proxy_enforced "${cid}"
  assert_egress_profile "${cid}"
  assert_write_boundaries "${cid}"
done

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
assert_mount_source "${claude_cid}" "/state" "${agentic_root}/claude/state"
assert_mount_source "${claude_cid}" "/logs" "${agentic_root}/claude/logs"
assert_mount_source "${claude_cid}" "/workspace" "${agentic_root}/claude/workspaces"
assert_mount_source "${codex_cid}" "/state" "${agentic_root}/codex/state"
assert_mount_source "${codex_cid}" "/logs" "${agentic_root}/codex/logs"
assert_mount_source "${codex_cid}" "/workspace" "${agentic_root}/codex/workspaces"
assert_mount_source "${opencode_cid}" "/state" "${agentic_root}/opencode/state"
assert_mount_source "${opencode_cid}" "/logs" "${agentic_root}/opencode/logs"
assert_mount_source "${opencode_cid}" "/workspace" "${agentic_root}/opencode/workspaces"
assert_mount_source "${vibestral_cid}" "/state" "${agentic_root}/vibestral/state"
assert_mount_source "${vibestral_cid}" "/logs" "${agentic_root}/vibestral/logs"
assert_mount_source "${vibestral_cid}" "/workspace" "${agentic_root}/vibestral/workspaces"
ok "agents volumes map to ${agentic_root}/<tool>/{state,logs,workspaces}"

ok "E2_agents_confinement passed"
