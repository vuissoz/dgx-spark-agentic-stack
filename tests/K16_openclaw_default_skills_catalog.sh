#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K16 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd python3

"${agent_bin}" down core >/tmp/agent-k16-down-pre.out 2>&1 || true
"${REPO_ROOT}/deployments/core/init_runtime.sh"
"${agent_bin}" up core >/tmp/agent-k16-up.out \
  || fail "agent up core failed for K16"

openclaw_cid="$(require_service_container openclaw)" || exit 1
wait_for_container_ready "${openclaw_cid}" 120 || fail "openclaw did not become ready for K16"

timeout 30 docker exec "${openclaw_cid}" sh -lc 'openclaw skills list --json >/tmp/agent-k16-openclaw-skills-list.json 2>/tmp/agent-k16-openclaw-skills-list.err' \
  || fail "openclaw skills list --json must succeed with the managed default skill catalog present"
docker exec "${openclaw_cid}" sh -lc "python3 - <<'PY'
import json
from pathlib import Path

expected = {
    'capability-evolver',
    'clawflows',
    'gog-google-one-gpt',
    'github-repo-manager',
    'summarize',
    'knowledge-base-rag',
    'mission-control',
    'code-reviewer',
    'decision-assistant',
    'red-team',
    'pre-mortem',
    'literature-scout',
    'paper-reviewer',
    'grant-writer',
    'citation-auditor',
    'architecture-reviewer',
    'documentation-builder',
    'dependency-auditor',
    'test-engineer',
    'knowledge-curator',
    'knowledge-gap-detector',
    'workspace-cartographer',
    'capability-evolver-plus-plus',
    'agent-security-watcher',
    'meeting-synthesizer',
}

payload = json.loads(Path('/tmp/agent-k16-openclaw-skills-list.json').read_text(encoding='utf-8'))
skills = payload.get('skills', []) if isinstance(payload, dict) else []
index = {}
for item in skills:
    if not isinstance(item, dict):
        continue
    keys = []
    for field in ('name', 'id', 'slug'):
        value = item.get(field)
        if isinstance(value, str) and value:
            keys.append(value)
    for key in keys:
        index[key] = item

missing = sorted(expected - set(index))
if missing:
    raise SystemExit('missing skills: ' + ', '.join(missing))

for skill in sorted(expected):
    item = index[skill]
    if item.get('disabled') is True:
        raise SystemExit(f'{skill}: skill is disabled')
    if item.get('blockedByAllowlist') is True:
        raise SystemExit(f'{skill}: blocked by allowlist')
    if item.get('blockedByAgentFilter') is True:
        raise SystemExit(f'{skill}: blocked by agent filter')
    if item.get('userInvocable') is False and item.get('modelVisible') is False:
        raise SystemExit(f'{skill}: skill is neither user-invocable nor model-visible')
PY" || fail "all requested managed default skills must be visible and usable in OpenClaw skills list"

ok "K16_openclaw_default_skills_catalog passed"
