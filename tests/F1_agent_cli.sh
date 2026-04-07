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
codex_cid="$(require_service_container agentic-codex)" || exit 1
vibestral_cid="$(require_service_container agentic-vibestral)" || exit 1
hermes_cid="$(require_service_container agentic-hermes)" || exit 1
wait_for_container_ready "${claude_cid}" 60 || fail "agentic-claude is not ready"
wait_for_container_ready "${codex_cid}" 60 || fail "agentic-codex is not ready"
wait_for_container_ready "${vibestral_cid}" 60 || fail "agentic-vibestral is not ready"
wait_for_container_ready "${hermes_cid}" 60 || fail "agentic-hermes is not ready"

ls_output="$("${agent_bin}" ls)"
printf '%s\n' "${ls_output}" | grep -q '^tool' || fail "agent ls output is missing header"
printf '%s\n' "${ls_output}" | grep -q '^claude' || fail "agent ls output is missing claude row"
printf '%s\n' "${ls_output}" | grep -q '^vibestral' || fail "agent ls output is missing vibestral row"
printf '%s\n' "${ls_output}" | grep -q '^hermes' || fail "agent ls output is missing hermes row"
printf '%s\n' "${ls_output}" | grep -q '^openclaw' || fail "agent ls output is missing openclaw row"
printf '%s\n' "${ls_output}" | grep -q '^pi-mono' || fail "agent ls output is missing pi-mono row"
printf '%s\n' "${ls_output}" | grep -q '^goose' || fail "agent ls output is missing goose row"
ok "agent ls returns a structured output"

project_name="f1-${USER:-agent}-$$"
AGENT_NO_ATTACH=1 AGENT_PROJECT_NAME="${project_name}" "${agent_bin}" claude >/tmp/agent-f1.out
grep -q 'persistent tmux session' /tmp/agent-f1.out \
  || fail "agent claude output is missing tmux persistence notice"
grep -q 'Ctrl-b d' /tmp/agent-f1.out \
  || fail "agent claude output is missing tmux detach shortcut notice"
grep -q 'attach reset sends Ctrl-c' /tmp/agent-f1.out \
  || fail "agent claude output is missing tmux attach reset warning"

timeout 20 docker exec "${claude_cid}" tmux has-session -t claude \
  || fail "agent claude did not create/keep tmux session"
timeout 20 docker exec "${claude_cid}" sh -lc "test -d '/workspace/${project_name}'" \
  || fail "agent claude did not create project workspace /workspace/${project_name}"
claude_path="$(timeout 20 docker exec "${claude_cid}" tmux display-message -p -t claude '#{pane_current_path}')"
[[ "${claude_path}" == "/workspace/${project_name}" ]] \
  || fail "agent claude tmux pane path mismatch (expected=/workspace/${project_name}, actual=${claude_path})"
ok "agent claude prepares tmux session and project workspace"

codex_project="f1-codex-${USER:-agent}-$$"
AGENT_NO_ATTACH=1 AGENT_PROJECT_NAME="${codex_project}" "${agent_bin}" codex >/tmp/agent-f1-codex.out

timeout 20 docker exec "${codex_cid}" tmux has-session -t codex \
  || fail "agent codex did not create/keep tmux session"
timeout 20 docker exec "${codex_cid}" sh -lc "test -d '/workspace/${codex_project}'" \
  || fail "agent codex did not create project workspace /workspace/${codex_project}"
codex_path="$(timeout 20 docker exec "${codex_cid}" tmux display-message -p -t codex '#{pane_current_path}')"
[[ "${codex_path}" == "/workspace/${codex_project}" ]] \
  || fail "agent codex tmux pane path mismatch (expected=/workspace/${codex_project}, actual=${codex_path})"
ok "agent codex prepares tmux session and project workspace"

vibestral_project="f1-vibestral-${USER:-agent}-$$"
AGENT_NO_ATTACH=1 AGENT_PROJECT_NAME="${vibestral_project}" "${agent_bin}" vibestral >/tmp/agent-f1-vibestral.out

timeout 20 docker exec "${vibestral_cid}" tmux has-session -t vibestral \
  || fail "agent vibestral did not create/keep tmux session"
timeout 20 docker exec "${vibestral_cid}" sh -lc "test -d '/workspace/${vibestral_project}'" \
  || fail "agent vibestral did not create project workspace /workspace/${vibestral_project}"
timeout 20 docker exec "${vibestral_cid}" sh -lc 'command -v vibe >/dev/null' \
  || fail "agent vibestral runtime is missing vibe CLI"
vibestral_path="$(timeout 20 docker exec "${vibestral_cid}" tmux display-message -p -t vibestral '#{pane_current_path}')"
[[ "${vibestral_path}" == "/workspace/${vibestral_project}" ]] \
  || fail "agent vibestral tmux pane path mismatch (expected=/workspace/${vibestral_project}, actual=${vibestral_path})"
ok "agent vibestral prepares tmux session, workspace, and vibe CLI runtime"

hermes_project="f1-hermes-${USER:-agent}-$$"
AGENT_NO_ATTACH=1 AGENT_PROJECT_NAME="${hermes_project}" "${agent_bin}" hermes >/tmp/agent-f1-hermes.out

timeout 20 docker exec "${hermes_cid}" tmux has-session -t hermes \
  || fail "agent hermes did not create/keep tmux session"
timeout 20 docker exec "${hermes_cid}" sh -lc "test -d '/workspace/${hermes_project}'" \
  || fail "agent hermes did not create project workspace /workspace/${hermes_project}"
timeout 20 docker exec "${hermes_cid}" sh -lc 'command -v hermes >/dev/null' \
  || fail "agent hermes runtime is missing hermes CLI"
hermes_path="$(timeout 20 docker exec "${hermes_cid}" tmux display-message -p -t hermes '#{pane_current_path}')"
[[ "${hermes_path}" == "/workspace/${hermes_project}" ]] \
  || fail "agent hermes tmux pane path mismatch (expected=/workspace/${hermes_project}, actual=${hermes_path})"
ok "agent hermes prepares tmux session, workspace, and hermes CLI runtime"

ok "F1_agent_cli passed"
