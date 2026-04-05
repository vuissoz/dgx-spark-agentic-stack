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
assert_cmd git

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
preflight = payload.get("preflight")

assert isinstance(results, list) and len(results) == 8
assert isinstance(doctor, dict)
assert isinstance(preflight, dict)
assert doctor.get("overall") == "partial"
assert preflight.get("status") == "skipped"
assert preflight.get("reset_agent_branches") is False

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
    plan_path = entry["artifacts_dir"] + "/plan.json"
    plan = json.load(open(plan_path, encoding="utf-8"))
    prompt = plan["prompt"]
    assert f"git pull --ff-only origin {branch}" in prompt
    assert f"git push origin HEAD:{branch}" in prompt
PY

summary_reset_json="${runtime_root}/summary-reset.json"
AGENTIC_ROOT="${runtime_root}" AGENTIC_COMPOSE_PROJECT="agentic-dev" \
  python3 "${REPO_ROOT}/deployments/optional/agent_repo_e2e.py" \
    --dry-run --reset-agent-branches >"${summary_reset_json}" \
  || fail "agent_repo_e2e dry-run planner with reset failed"

python3 - "${summary_reset_json}" <<'PY' || fail "agent_repo_e2e reset dry-run summary schema is invalid"
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
preflight = payload.get("preflight")

assert isinstance(preflight, dict)
assert preflight.get("status") == "planned"
assert preflight.get("reset_agent_branches") is True
branches = preflight.get("branches") or {}
assert len(branches) == 8
for entry in branches.values():
    assert entry["reset_applied"] is False
PY

python3 - "${REPO_ROOT}" "${runtime_root}" <<'PY' || fail "agent_repo_e2e branch reset integration failed"
from __future__ import annotations

import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys

repo_root = pathlib.Path(sys.argv[1])
runtime_root = pathlib.Path(sys.argv[2]) / "reset-integration"
origin_dir = runtime_root / "origin.git"
seed_dir = runtime_root / "seed"
verify_dir = runtime_root / "verify"
artifact_root = runtime_root / "artifacts"
template_dir = repo_root / "examples" / "optional" / "eight-queens-agent-e2e"
module_path = repo_root / "deployments" / "optional" / "agent_repo_e2e.py"

runtime_root.mkdir(parents=True, exist_ok=True)


def run(args: list[str], *, cwd: pathlib.Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=str(cwd) if cwd is not None else None,
        text=True,
        capture_output=True,
        check=check,
    )


def copy_tree(source: pathlib.Path, destination: pathlib.Path) -> None:
    for item in source.rglob("*"):
        relative = item.relative_to(source)
        target = destination / relative
        if item.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item, target)


def remote_head(repo_url: str, branch: str) -> str:
    proc = run(["git", "ls-remote", "--heads", repo_url, branch])
    line = proc.stdout.strip().splitlines()
    assert line, branch
    return line[0].split()[0]


run(["git", "init", "--bare", str(origin_dir)])
run(["git", "clone", origin_dir.as_uri(), str(seed_dir)])
run(["git", "config", "user.name", "System Manager"], cwd=seed_dir)
run(["git", "config", "user.email", "system-manager@forge.agentic.local"], cwd=seed_dir)
copy_tree(template_dir, seed_dir)
run(["git", "add", "-A"], cwd=seed_dir)
run(["git", "commit", "-m", "Seed reference repository"], cwd=seed_dir)
run(["git", "branch", "-M", "main"], cwd=seed_dir)
run(["git", "push", "origin", "main"], cwd=seed_dir)
main_head = run(["git", "rev-parse", "HEAD"], cwd=seed_dir).stdout.strip()

problem_file = seed_dir / "src" / "eight_queens.py"
sentinel = 'raise NotImplementedError("Implement solve_eight_queens()")'
solution = "    return [0, 4, 7, 5, 2, 6, 1, 3]\n"
solved_heads: dict[str, str] = {}
for branch in ("agent/codex", "agent/goose"):
    run(["git", "checkout", "-B", branch, "main"], cwd=seed_dir)
    problem_file.write_text(problem_file.read_text(encoding="utf-8").replace(f"    {sentinel}\n", solution), encoding="utf-8")
    run(["git", "add", "src/eight_queens.py"], cwd=seed_dir)
    run(["git", "commit", "-m", f"Solve eight queens on {branch}"], cwd=seed_dir)
    run(["git", "push", "origin", f"HEAD:{branch}"], cwd=seed_dir)
    solved_heads[branch] = run(["git", "rev-parse", "HEAD"], cwd=seed_dir).stdout.strip()
    run(["git", "checkout", "-B", "main", "origin/main"], cwd=seed_dir)
    run(["git", "reset", "--hard", "origin/main"], cwd=seed_dir)

spec = importlib.util.spec_from_file_location("agent_repo_e2e", module_path)
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(module)
module.git_forge_api_request = lambda *args, **kwargs: {"name": "eight-queens-agent-e2e"}
module.read_secret = lambda secret_name: "dummy"

clone_url = origin_dir.as_uri()
state = {
    "host_url": "http://127.0.0.1:13010",
    "admin_user": "system-manager",
    "shared_namespace": "agentic",
    "reference_repository": "eight-queens-agent-e2e",
    "reference_clone_url_internal": clone_url,
    "reference_clone_url_host": clone_url,
}
selected_agents = ["codex", "goose"]

skipped = module.reset_agent_branches_if_requested(
    state=state,
    repo_name="eight-queens-agent-e2e",
    clone_url=clone_url,
    selected_agents=selected_agents,
    artifact_root=artifact_root / "skipped",
    reset_agent_branches=False,
    dry_run=False,
)
assert skipped["status"] == "skipped"
assert remote_head(clone_url, "agent/codex") == solved_heads["agent/codex"]
assert remote_head(clone_url, "agent/goose") == solved_heads["agent/goose"]

planned = module.reset_agent_branches_if_requested(
    state=state,
    repo_name="eight-queens-agent-e2e",
    clone_url=clone_url,
    selected_agents=selected_agents,
    artifact_root=artifact_root / "planned",
    reset_agent_branches=True,
    dry_run=True,
)
assert planned["status"] == "planned"

completed = module.reset_agent_branches_if_requested(
    state=state,
    repo_name="eight-queens-agent-e2e",
    clone_url=clone_url,
    selected_agents=selected_agents,
    artifact_root=artifact_root / "completed",
    reset_agent_branches=True,
    dry_run=False,
)
assert completed["status"] == "completed"
for agent_name in selected_agents:
    branch = module.AGENT_MATRIX[agent_name]["branch"]
    entry = completed["branches"][agent_name]
    assert entry["before_head"] == solved_heads[branch]
    assert entry["after_head"] == main_head
    assert entry["aligned_to_main"] is True

run(["git", "clone", clone_url, str(verify_dir)])
run(["git", "checkout", "-B", "main", "origin/main"], cwd=verify_dir)
main_text = (verify_dir / "src" / "eight_queens.py").read_text(encoding="utf-8")
assert sentinel in main_text
for branch in ("agent/codex", "agent/goose"):
    run(["git", "checkout", "-B", branch, f"origin/{branch}"], cwd=verify_dir)
    branch_text = (verify_dir / "src" / "eight_queens.py").read_text(encoding="utf-8")
    assert sentinel in branch_text
PY

ok "K12_agent_repo_e2e passed"
