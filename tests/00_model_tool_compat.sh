#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/model_compat.sh
source "${REPO_ROOT}/scripts/lib/model_compat.sh"

reason="$(agentic_tool_call_model_incompatibility_reason "qwen3.5:35b")" \
  || fail "qwen3.5:35b must be flagged as tool-call incompatible"
[[ "${reason}" == *"pseudo tool tags"* ]] \
  || fail "incompatibility reason must mention pseudo tool tags"

reason_with_provider="$(agentic_tool_call_model_incompatibility_reason "openai/qwen3.5:35b")" \
  || fail "provider-qualified qwen3.5:35b must be flagged as tool-call incompatible"
[[ "${reason_with_provider}" == *"pseudo tool tags"* ]] \
  || fail "provider-qualified incompatibility reason must mention pseudo tool tags"

recommended="$(agentic_tool_call_model_recommendation "qwen3.5:35b")" \
  || fail "qwen3.5:35b must return a recommended replacement model"
[[ "${recommended}" == "qwen3-coder:30b" ]] \
  || fail "recommended replacement model must be qwen3-coder:30b"

if agentic_tool_call_model_incompatibility_reason "qwen3-coder:30b" >/dev/null 2>&1; then
  fail "qwen3-coder:30b must not be flagged as tool-call incompatible"
fi

ok "tool-call compatibility helper blocks qwen3.5:35b and keeps qwen3-coder:30b allowed"
ok "00_model_tool_compat passed"
