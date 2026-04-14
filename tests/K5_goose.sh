#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K5 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker

"${agent_bin}" down optional >/tmp/agent-k5-down-pre.out 2>&1 || true
"${REPO_ROOT}/deployments/optional/init_runtime.sh"

agentic_root="${AGENTIC_ROOT}"
goose_workspaces_dir="${AGENTIC_GOOSE_WORKSPACES_DIR}"
goose_context_limit="${AGENTIC_GOOSE_CONTEXT_LIMIT:-${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-262144}}"
context_budget_tokens="${AGENTIC_CONTEXT_BUDGET_TOKENS:-${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-50909}}"
context_soft_tokens="${AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS:-38181}"
context_danger_tokens="${AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS:-45818}"
runtime_goose_context_limit_file="${agentic_root}/deployments/runtime.env"
if [[ -f "${runtime_goose_context_limit_file}" ]]; then
  runtime_goose_context_limit="$(runtime_env_value "${agentic_root}" "AGENTIC_GOOSE_CONTEXT_LIMIT")"
  if [[ -n "${runtime_goose_context_limit}" ]]; then
    goose_context_limit="${runtime_goose_context_limit}"
  fi
  runtime_context_budget_tokens="$(runtime_env_value "${agentic_root}" "AGENTIC_CONTEXT_BUDGET_TOKENS")"
  if [[ -n "${runtime_context_budget_tokens}" ]]; then
    context_budget_tokens="${runtime_context_budget_tokens}"
  fi
  runtime_context_soft_tokens="$(runtime_env_value "${agentic_root}" "AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS")"
  if [[ -n "${runtime_context_soft_tokens}" ]]; then
    context_soft_tokens="${runtime_context_soft_tokens}"
  fi
  runtime_context_danger_tokens="$(runtime_env_value "${agentic_root}" "AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS")"
  if [[ -n "${runtime_context_danger_tokens}" ]]; then
    context_danger_tokens="${runtime_context_danger_tokens}"
  fi
fi
[[ "${goose_context_limit}" =~ ^[0-9]+$ ]] || fail "AGENTIC_GOOSE_CONTEXT_LIMIT must be numeric (got ${goose_context_limit})"
(( goose_context_limit >= 2048 )) || fail "AGENTIC_GOOSE_CONTEXT_LIMIT must be >= 2048 (got ${goose_context_limit})"
goose_context_display="$((goose_context_limit / 1000))k"
install -d -m 0750 "${agentic_root}/deployments/optional"

cat >"${agentic_root}/deployments/optional/goose.request" <<'REQ'
need=Provide an isolated Goose runtime for controlled optional workflows.
success=Service is healthy and Goose session storage works with read-only rootfs.
owner=ops
expires_at=2099-12-31
REQ
chmod 0640 "${agentic_root}/deployments/optional/goose.request"

"${agent_bin}" doctor >/tmp/agent-k5-doctor.out \
  || fail "precondition failed: doctor must be green before validating K5"

AGENTIC_OPTIONAL_MODULES=goose "${agent_bin}" up optional >/tmp/agent-k5-up.out \
  || fail "agent up optional (goose) failed"

goose_cid="$(require_service_container optional-goose)" || exit 1
wait_for_container_ready "${goose_cid}" 120 || fail "optional-goose did not become ready"
assert_container_security "${goose_cid}" || fail "optional-goose container security baseline failed"
assert_proxy_enforced "${goose_cid}" || fail "optional-goose proxy env baseline failed"
assert_no_docker_sock_mount "${goose_cid}" || fail "optional-goose must not mount docker.sock"
timeout 20 docker exec "${goose_cid}" sh -lc \
  'command -v git >/dev/null && command -v python3 >/dev/null && python3 -c "import pytest" >/dev/null && command -v goose >/dev/null' \
  || fail "optional-goose repo task toolchain must provide goose, git, python3, and pytest"

env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${goose_cid}")"
echo "${env_dump}" | grep -q '^HOME=/state/home$' \
  || fail "optional-goose must set HOME=/state/home"
echo "${env_dump}" | grep -q '^XDG_CONFIG_HOME=/state/home/.config$' \
  || fail "optional-goose must set XDG_CONFIG_HOME=/state/home/.config"
echo "${env_dump}" | grep -q '^XDG_DATA_HOME=/state/home/.local/share$' \
  || fail "optional-goose must set XDG_DATA_HOME=/state/home/.local/share"
echo "${env_dump}" | grep -q '^XDG_STATE_HOME=/state/home/.local/state$' \
  || fail "optional-goose must set XDG_STATE_HOME=/state/home/.local/state"
echo "${env_dump}" | grep -q '^OLLAMA_HOST=http://ollama-gate:11435$' \
  || fail "optional-goose must set OLLAMA_HOST=http://ollama-gate:11435"
echo "${env_dump}" | grep -q "^GOOSE_CONTEXT_LIMIT=${goose_context_limit}$" \
  || fail "optional-goose must set GOOSE_CONTEXT_LIMIT=${goose_context_limit}"
echo "${env_dump}" | grep -q "^AGENTIC_CONTEXT_BUDGET_TOKENS=${context_budget_tokens}$" \
  || fail "optional-goose must set AGENTIC_CONTEXT_BUDGET_TOKENS=${context_budget_tokens}"
echo "${env_dump}" | grep -q "^AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS=${context_soft_tokens}$" \
  || fail "optional-goose must set AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS=${context_soft_tokens}"
echo "${env_dump}" | grep -q "^AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS=${context_danger_tokens}$" \
  || fail "optional-goose must set AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS=${context_danger_tokens}"
echo "${env_dump}" | grep -q "^GOOSE_CONTEXT_COMPACTION_SOFT_TOKENS=${context_soft_tokens}$" \
  || fail "optional-goose must set GOOSE_CONTEXT_COMPACTION_SOFT_TOKENS=${context_soft_tokens}"
echo "${env_dump}" | grep -q "^GOOSE_CONTEXT_COMPACTION_DANGER_TOKENS=${context_danger_tokens}$" \
  || fail "optional-goose must set GOOSE_CONTEXT_COMPACTION_DANGER_TOKENS=${context_danger_tokens}"

mount_dump="$(docker inspect --format '{{range .Mounts}}{{printf "%s|%s|%v\n" .Source .Destination .RW}}{{end}}' "${goose_cid}")"
echo "${mount_dump}" | grep -q '|/state|true$' \
  || fail "optional-goose must mount /state as writable"
echo "${mount_dump}" | grep -q '|/logs|true$' \
  || fail "optional-goose must mount /logs as writable"
echo "${mount_dump}" | grep -q '|/workspace|true$' \
  || fail "optional-goose must mount /workspace as writable"
workspace_mount_source="$(printf '%s\n' "${mount_dump}" | awk -F'|' '$2=="/workspace" {print $1; exit}')"
[[ -n "${workspace_mount_source}" ]] || fail "optional-goose workspace mount source is missing"
workspace_mount_source="$(readlink -f "${workspace_mount_source}" 2>/dev/null || printf '%s\n' "${workspace_mount_source}")"
expected_workspace_source="$(readlink -f "${goose_workspaces_dir}" 2>/dev/null || printf '%s\n' "${goose_workspaces_dir}")"
[[ "${workspace_mount_source}" == "${expected_workspace_source}" ]] \
  || fail "optional-goose /workspace mount source mismatch (expected=${expected_workspace_source}, actual=${workspace_mount_source})"

timeout 30 docker exec "${goose_cid}" sh -lc 'goose session list >/tmp/goose-k5-session-list.out 2>&1' \
  || fail "optional-goose goose session list failed"
timeout 30 docker exec "${goose_cid}" sh -lc 'test -d /state/home && test -w /state/home' \
  || fail "optional-goose home must be writable at /state/home"
timeout 30 docker exec "${goose_cid}" sh -lc 'test -d /state/home/.local/share/goose/sessions && test -w /state/home/.local/share/goose/sessions' \
  || fail "optional-goose sessions dir must be writable"
timeout 30 docker exec "${goose_cid}" sh -lc 'test -d /state/home/.local/state/goose/logs && test -w /state/home/.local/state/goose/logs' \
  || fail "optional-goose logs dir must be writable"
timeout 30 docker exec "${goose_cid}" sh -lc 'test -f /state/home/.local/share/goose/sessions/sessions.db' \
  || fail "optional-goose sessions database must persist in /state/home/.local/share/goose/sessions/sessions.db"
goose_banner="$(timeout 20 docker exec "${goose_cid}" sh -lc 'goose session -n k5-context-display-check' 2>&1 || true)"
if printf '%s\n' "${goose_banner}" | grep -q "/${goose_context_display}"; then
  ok "optional-goose banner exposes context usage '/${goose_context_display}'"
elif printf '%s\n' "${goose_banner}" | grep -Eqi 'not connected|connection refused|provider|auth'; then
  ok "optional-goose session command reaches provider setup before banner; GOOSE_CONTEXT_LIMIT env contract is enforced"
else
  fail "optional-goose banner must expose context usage '/${goose_context_display}' or fail explicitly before provider connection"
fi

goose_pwd="$(timeout 20 docker exec "${goose_cid}" sh -lc 'pwd')"
[[ "${goose_pwd}" == "/workspace" ]] \
  || fail "optional-goose working directory mismatch (expected=/workspace, actual=${goose_pwd})"

goose_project="k5-goose-${USER:-agent}-$$"
AGENT_NO_ATTACH=1 "${agent_bin}" goose "${goose_project}" >/tmp/agent-k5-goose.out \
  || fail "agent goose attach contract failed"
grep -q 'direct Goose CLI session' /tmp/agent-k5-goose.out \
  || fail "agent goose output is missing direct-session notice"
timeout 20 docker exec "${goose_cid}" sh -lc "test -d '/workspace/${goose_project}'" \
  || fail "agent goose did not create project workspace /workspace/${goose_project}"
goose_path="$(timeout 20 docker exec "${goose_cid}" sh -lc "cd '/workspace/${goose_project}' && pwd")"
[[ "${goose_path}" == "/workspace/${goose_project}" ]] \
  || fail "agent goose working directory mismatch (expected=/workspace/${goose_project}, actual=${goose_path})"

assert_no_public_bind || fail "goose activation must not introduce non-loopback listeners"

ok "K5_goose passed"
