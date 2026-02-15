#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F1 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker

claude_cid="$(require_service_container agentic-claude)" || exit 1
wait_for_container_ready "${claude_cid}" 60 || fail "agentic-claude is not ready"

ls_output="$("${agent_bin}" ls)"
printf '%s\n' "${ls_output}" | grep -q '^tool' || fail "agent ls output is missing header"
printf '%s\n' "${ls_output}" | grep -q '^claude' || fail "agent ls output is missing claude row"
ok "agent ls returns a structured output"

project_name="f1-${USER:-agent}-$$"
AGENT_NO_ATTACH=1 AGENT_PROJECT_NAME="${project_name}" "${agent_bin}" claude >/tmp/agent-f1.out

timeout 20 docker exec "${claude_cid}" tmux has-session -t claude \
  || fail "agent claude did not create/keep tmux session"
timeout 20 docker exec "${claude_cid}" sh -lc "test -d '/workspace/${project_name}'" \
  || fail "agent claude did not create project workspace /workspace/${project_name}"
ok "agent claude prepares tmux session and project workspace"

ok "F1_agent_cli passed"
