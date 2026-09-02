#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd docker

runtime_root="$(mktemp -d)"
trap 'rm -rf "${runtime_root}"' EXIT

tokens=65536
soft_tokens=49152
danger_tokens=58982

set_output="$(
  AGENTIC_PROFILE=rootless-dev \
  AGENTIC_ROOT="${runtime_root}" \
  AGENTIC_COMPOSE_PROJECT="agentic-context-test-$$" \
  "${REPO_ROOT}/agent" context set "${tokens}"
)"
printf '%s\n' "${set_output}" | grep -q "^context window persisted=${tokens}$" \
  || fail "agent context set must report the persisted context window"
printf '%s\n' "${set_output}" | grep -q "^context compaction soft=${soft_tokens} danger=${danger_tokens}$" \
  || fail "agent context set must report derived compaction thresholds"

runtime_env="${runtime_root}/deployments/runtime.env"
[[ -f "${runtime_env}" ]] || fail "agent context set must create runtime.env"

for entry in \
  "AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW=${tokens}" \
  "OLLAMA_CONTEXT_LENGTH=${tokens}" \
  "AGENTIC_GOOSE_CONTEXT_LIMIT=${tokens}" \
  "AGENTIC_CONTEXT_BUDGET_TOKENS=${tokens}" \
  "AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS=${soft_tokens}" \
  "AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS=${danger_tokens}"; do
  grep -qxF "${entry}" "${runtime_env}" || fail "runtime.env missing ${entry}"
done
ok "agent context set persists all aligned runtime values"

show_output="$(
  AGENTIC_PROFILE=rootless-dev \
  AGENTIC_ROOT="${runtime_root}" \
  AGENTIC_COMPOSE_PROJECT="agentic-context-test-$$" \
  "${REPO_ROOT}/agent" context show
)"
for entry in \
  "default_model_context_window=${tokens}" \
  "ollama_context_length=${tokens}" \
  "goose_context_limit=${tokens}" \
  "context_budget_tokens=${tokens}" \
  "context_compaction_soft_tokens=${soft_tokens}" \
  "context_compaction_danger_tokens=${danger_tokens}" \
  "openclaw_active_provider=custom-ollama-gate-11435" \
  "openclaw_active_context_window=${tokens}" \
  "openclaw_catalog_context_note=active_provider_only" \
  "runtime_env=${runtime_env}"; do
  printf '%s\n' "${show_output}" | grep -qxF "${entry}" \
    || fail "agent context show missing ${entry}"
done
ok "agent context show reports the active OpenClaw route separately from catalog metadata"

set +e
AGENTIC_PROFILE=rootless-dev AGENTIC_ROOT="${runtime_root}" "${REPO_ROOT}/agent" context set 2047 \
  >/tmp/agent-context-too-small.out 2>&1
invalid_rc=$?
set -e
[[ "${invalid_rc}" -ne 0 ]] || fail "agent context set must reject windows below 2048"
grep -q 'context tokens must be >= 2048' /tmp/agent-context-too-small.out \
  || fail "agent context set rejection must be actionable"
grep -qxF "AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW=${tokens}" "${runtime_env}" \
  || fail "invalid context update must not mutate the persisted window"
ok "agent context set rejects invalid updates without mutating runtime state"

ok "F28_context_command passed"
