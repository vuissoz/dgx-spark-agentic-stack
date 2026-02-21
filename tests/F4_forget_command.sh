#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F4 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

runtime_root="$(mktemp -d)"
compose_project="agentic-f4-${RANDOM}"
network_name="agentic-f4-${RANDOM}"
llm_network_name="agentic-f4-llm-${RANDOM}"
egress_network_name="agentic-f4-egress-${RANDOM}"

run_agent() {
  AGENTIC_PROFILE=rootless-dev \
  AGENTIC_ROOT="${runtime_root}" \
  AGENTIC_COMPOSE_PROJECT="${compose_project}" \
  AGENTIC_NETWORK="${network_name}" \
  AGENTIC_LLM_NETWORK="${llm_network_name}" \
  AGENTIC_EGRESS_NETWORK="${egress_network_name}" \
    "${agent_bin}" "$@"
}

cleanup() {
  rm -rf "${runtime_root}"
}
trap cleanup EXIT

AGENTIC_PROFILE=rootless-dev AGENTIC_ROOT="${runtime_root}" \
  "${REPO_ROOT}/deployments/bootstrap/init_fs.sh" >/dev/null
AGENTIC_PROFILE=rootless-dev AGENTIC_ROOT="${runtime_root}" \
  "${REPO_ROOT}/deployments/core/init_runtime.sh" >/dev/null
AGENTIC_PROFILE=rootless-dev AGENTIC_ROOT="${runtime_root}" \
  AGENT_RUNTIME_UID="$(id -u)" AGENT_RUNTIME_GID="$(id -g)" \
  "${REPO_ROOT}/deployments/agents/init_runtime.sh" >/dev/null
AGENTIC_PROFILE=rootless-dev AGENTIC_ROOT="${runtime_root}" \
  AGENT_RUNTIME_UID="$(id -u)" AGENT_RUNTIME_GID="$(id -g)" \
  "${REPO_ROOT}/deployments/ui/init_runtime.sh" >/dev/null
AGENTIC_PROFILE=rootless-dev AGENTIC_ROOT="${runtime_root}" \
  AGENT_RUNTIME_UID="$(id -u)" AGENT_RUNTIME_GID="$(id -g)" \
  "${REPO_ROOT}/deployments/optional/init_runtime.sh" >/dev/null
ok "runtime initialized for forget command checks"

touch "${runtime_root}/vibestral/workspaces/.f4-vibestral-marker"
touch "${runtime_root}/codex/workspaces/.f4-codex-marker"
touch "${runtime_root}/claude/workspaces/.f4-claude-marker"

set +e
printf '\n' | run_agent forget vibestral >/tmp/agent-f4-deny.out 2>&1
deny_rc=$?
set -e
[[ "${deny_rc}" -ne 0 ]] || fail "forget must refuse when confirmation defaults to No"
ok "forget refuses without explicit confirmation"

printf 'yes\nyes\n' | run_agent forget vibestral >/tmp/agent-f4-vibestral.out
[[ ! -e "${runtime_root}/vibestral/workspaces/.f4-vibestral-marker" ]] \
  || fail "vibestral marker must be removed after interactive forget"
[[ -d "${runtime_root}/vibestral/workspaces" ]] || fail "vibestral workspace dir must be recreated"
[[ -d "${runtime_root}/vibestral/state" ]] || fail "vibestral state dir must be recreated"
[[ -d "${runtime_root}/vibestral/logs" ]] || fail "vibestral logs dir must be recreated"
ok "forget vibestral recreates runtime layout"

backup_count="$(find "${runtime_root}/deployments/forget-backups" -maxdepth 1 -type f -name '*-vibestral.tar.gz' | wc -l | tr -d ' ')"
[[ "${backup_count}" -gt 0 ]] || fail "forget vibestral must produce a backup archive by default"
ok "forget vibestral creates backup archive"

run_agent forget codex --yes --no-backup >/tmp/agent-f4-codex.out
[[ ! -e "${runtime_root}/codex/workspaces/.f4-codex-marker" ]] \
  || fail "codex marker must be removed after forget codex"
[[ -e "${runtime_root}/claude/workspaces/.f4-claude-marker" ]] \
  || fail "forget codex must not remove claude marker"
ok "forget codex keeps other agent workspaces intact"

run_agent forget codex --yes --no-backup >/tmp/agent-f4-codex-idempotent.out \
  || fail "forget codex must be idempotent on an already empty target"
ok "forget command is idempotent for codex target"

changes_log="${runtime_root}/deployments/changes.log"
[[ -s "${changes_log}" ]] || fail "forget command must append to changes.log"
grep -q 'target=vibestral' "${changes_log}" || fail "changes.log missing vibestral forget entry"
grep -q 'target=codex' "${changes_log}" || fail "changes.log missing codex forget entry"
ok "forget command logs actions in changes.log"

ok "F4_forget_command passed"
