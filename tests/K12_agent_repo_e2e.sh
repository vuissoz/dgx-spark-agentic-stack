#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K12 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

assert_cmd python3

runtime_root="$(mktemp -d)"
trap 'rm -rf "${runtime_root}"' EXIT
bootstrap_dir="${runtime_root}/optional/git/bootstrap"
artifacts_dir="${runtime_root}/deployments/validation/agent-repo-e2e"
mkdir -p "${bootstrap_dir}" "${artifacts_dir}"

cat >"${bootstrap_dir}/git-forge-bootstrap.json" <<'JSON'
{
  "host_url": "http://127.0.0.1:13010",
  "internal_url": "http://optional-forgejo:3000",
  "admin_user": "system-manager",
  "shared_namespace": "agentic",
  "shared_team": "agents",
  "shared_repository": "shared-workbench",
  "reference_repository": "eight-queens-agent-e2e",
  "reference_clone_url_host": "http://127.0.0.1:13010/agentic/eight-queens-agent-e2e.git",
  "reference_clone_url_internal": "http://optional-forgejo:3000/agentic/eight-queens-agent-e2e.git",
  "reference_branch_policy": {
    "protected_branch": "main",
    "main_push_allowlist_users": ["system-manager"],
    "agent_branches": [
      "agent/codex",
      "agent/openclaw",
      "agent/claude",
      "agent/opencode",
      "agent/openhands",
      "agent/pi-mono",
      "agent/goose",
      "agent/vibestral"
    ]
  },
  "managed_users": [
    "openclaw",
    "openhands",
    "comfyui",
    "claude",
    "codex",
    "opencode",
    "vibestral",
    "pi-mono",
    "goose"
  ],
  "updated_at": "2026-03-29T00:00:00Z"
}
JSON

summary_json="${runtime_root}/summary.json"
AGENTIC_ROOT="${runtime_root}" AGENTIC_COMPOSE_PROJECT="agentic-dev" \
  python3 "${REPO_ROOT}/deployments/optional/agent_repo_e2e.py" \
    --dry-run >"${summary_json}" \
  || fail "agent_repo_e2e dry-run planner failed"

python3 - "${summary_json}" <<'PY' || fail "agent_repo_e2e dry-run summary schema is invalid"
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
results = payload.get("results")
doctor = payload.get("doctor")

assert isinstance(results, list) and len(results) == 8
assert isinstance(doctor, dict)
assert doctor.get("overall") == "partial"

agents = {entry["agent"]: entry for entry in results}
expected = {
    "codex": "agent/codex",
    "openclaw": "agent/openclaw",
    "claude": "agent/claude",
    "opencode": "agent/opencode",
    "openhands": "agent/openhands",
    "pi-mono": "agent/pi-mono",
    "goose": "agent/goose",
    "vibestral": "agent/vibestral",
}
assert set(agents) == set(expected)
for agent, branch in expected.items():
    entry = agents[agent]
    assert entry["branch"] == branch
    assert entry["status"] == "planned"
    assert entry["category"] == "planned"
    assert entry["workspace"].startswith("/workspace/eight-queens-agent-e2e-")
PY

ok "K12_agent_repo_e2e passed"
