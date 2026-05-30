#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

agent_script="${REPO_ROOT}/scripts/agent.sh"
[[ -f "${agent_script}" ]] || fail "scripts/agent.sh is missing"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

export AGENTIC_ROOT="${work_dir}"
export AGENTIC_REPO_ROOT="${REPO_ROOT}"
export AGENTIC_DEFAULT_MODEL="nemotron-cascade-2:30b"
export AGENTIC_CONTEXT_BUDGET_TOKENS="98304"
export AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW="98304"
export OLLAMA_CONTEXT_LENGTH="98304"
export AGENTIC_SKIP_OPTIONAL_GATING="1"

state_dir="${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home"
agent_dir="${state_dir}/.openclaw/agents/main/agent"
sessions_dir="${state_dir}/.openclaw/agents/main/sessions"
mkdir -p "${agent_dir}" "${sessions_dir}"

cat >"${state_dir}/openclaw.state.json" <<'JSON'
{
  "models": {
    "providers": {
      "custom-ollama-gate-11435": {
        "api": "openai-completions",
        "models": [
          {
            "id": "nemotron-cascade-2:30b",
            "name": "nemotron-cascade-2:30b (Custom Provider)",
            "contextWindow": 16000,
            "maxTokens": 4096
          }
        ]
      }
    }
  }
}
JSON

cat >"${agent_dir}/models.json" <<'JSON'
{
  "providers": {
    "custom-ollama-gate-11435": {
      "api": "openai-completions",
      "models": [
        {
          "id": "nemotron-cascade-2:30b",
          "name": "nemotron-cascade-2:30b (Custom Provider)",
          "contextWindow": 16000,
          "maxTokens": 4096
        }
      ]
    }
  }
}
JSON

cat >"${sessions_dir}/sessions.json" <<'JSON'
{
  "agent:main:main": {
    "modelProvider": "custom-ollama-gate-11435",
    "model": "nemotron-cascade-2:30b",
    "contextTokens": 16000,
    "totalTokens": 16166,
    "remainingTokens": 0,
    "percentUsed": 101
  }
}
JSON

# Load the exact helper body from scripts/agent.sh without triggering its CLI entrypoint.
helper_file="${work_dir}/reconcile-openclaw-context.sh"
{
  printf '%s\n' 'die() { echo "ERROR: $*" >&2; exit 1; }'
  sed -n '/^reconcile_openclaw_context_metadata() {/,/^}/p' "${agent_script}"
} >"${helper_file}"
# shellcheck source=/dev/null
source "${helper_file}"

reconcile_openclaw_context_metadata

python3 "${REPO_ROOT}/deployments/optional/openclaw_context_reconcile.py" check \
  --state-file "${state_dir}/openclaw.state.json" \
  --state-dir "${state_dir}" \
  --model-id "${AGENTIC_DEFAULT_MODEL}" \
  --context-window "${AGENTIC_CONTEXT_BUDGET_TOKENS}" >/tmp/k15-openclaw-context-check.out \
  || fail "optional gating reconcile helper must realign OpenClaw context metadata"

ok "K15_optional_gating_openclaw_context_reconcile passed"
