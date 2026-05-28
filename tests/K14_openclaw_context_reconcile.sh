#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

state_dir="${work_dir}/state/cli/openclaw-home"
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

python3 "${REPO_ROOT}/deployments/optional/openclaw_context_reconcile.py" reconcile \
  --state-file "${state_dir}/openclaw.state.json" \
  --state-dir "${state_dir}" \
  --model-id "nemotron-cascade-2:30b" \
  --context-window 50909 >/tmp/k14-openclaw-context-reconcile.out \
  || fail "openclaw context reconcile command failed"

python3 "${REPO_ROOT}/deployments/optional/openclaw_context_reconcile.py" check \
  --state-file "${state_dir}/openclaw.state.json" \
  --state-dir "${state_dir}" \
  --model-id "nemotron-cascade-2:30b" \
  --context-window 50909 >/tmp/k14-openclaw-context-check.out \
  || fail "openclaw context check must pass after reconcile"

python3 - "${state_dir}" <<'PY' >/dev/null 2>&1 || fail "reconcile must update state, model registry, and session context metadata"
import json
import pathlib
import sys

state_dir = pathlib.Path(sys.argv[1])
state = json.loads((state_dir / "openclaw.state.json").read_text(encoding="utf-8"))
models = json.loads((state_dir / ".openclaw/agents/main/agent/models.json").read_text(encoding="utf-8"))
sessions = json.loads((state_dir / ".openclaw/agents/main/sessions/sessions.json").read_text(encoding="utf-8"))

provider = state["models"]["providers"]["custom-ollama-gate-11435"]
model = provider["models"][0]
assert model["contextWindow"] == 50909
assert model["maxTokens"] == 4096

agent_model = models["providers"]["custom-ollama-gate-11435"]["models"][0]
assert agent_model["contextWindow"] == 50909

session = sessions["agent:main:main"]
assert session["contextTokens"] == 50909
assert session["remainingTokens"] == 34743
assert session["percentUsed"] == 31
PY

ok "K14_openclaw_context_reconcile passed"
