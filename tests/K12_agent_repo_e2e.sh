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
grep -q 'GATE_QUEUE_WAIT_TIMEOUT_SECONDS: 60' "${REPO_ROOT}/compose/compose.core.yml" \
  || fail "compose.core.yml must set GATE_QUEUE_WAIT_TIMEOUT_SECONDS to 60"

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
assert preflight.get("attempts_requested") == 5
assert preflight.get("validation_policy") == "at_least_one_success"
assert preflight.get("success_threshold") == 1
assert preflight.get("attempt_reset_policy") == "none"
assert doctor.get("attempt_totals") == {"requested": 40, "successes": 0, "failures": 40}
assert doctor.get("validation_policy") == "at_least_one_success"
assert doctor.get("success_threshold") == 1

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
    assert entry["attempts_requested"] == 5
    assert entry["validation_policy"] == "at_least_one_success"
    assert entry["success_threshold"] == 1
    stats = entry["attempt_statistics"]
    assert stats["requested"] == 5
    assert stats["successes"] == 0
    assert stats["failures"] == 5
    assert stats["success_rate"] == 0.0
    assert len(entry["attempts"]) == 5
    assert all(item["status"] == "planned" for item in entry["attempts"])
    plan_path = entry["artifacts_dir"] + "/plan.json"
    plan = json.load(open(plan_path, encoding="utf-8"))
    prompt = plan["prompt"]
    assert plan["attempts_requested"] == 5
    assert plan["validation_policy"] == "at_least_one_success"
    assert plan["success_threshold"] == 1
    assert f"git pull --ff-only origin {branch}" in prompt
    assert f"git push origin HEAD:{branch}" in prompt
    assert "The shell is '/bin/sh'" in prompt
    assert "git add src/eight_queens.py" in prompt
    assert 'git commit -m "Implement solve_eight_queens()"' in prompt
    assert "Do not use here-strings, heredocs" in prompt
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
assert preflight.get("preflight_clone_url") == "http://127.0.0.1:13010/agentic/eight-queens-agent-e2e.git"
assert preflight.get("attempts_requested") == 5
assert preflight.get("validation_policy") == "at_least_one_success"
assert preflight.get("success_threshold") == 1
assert preflight.get("attempt_reset_policy") == "before_each_attempt"
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
import urllib.error

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
assert (seed_dir / ".gitignore").is_file()
assert (seed_dir / "AGENT.md").is_file()
gitignore = (seed_dir / ".gitignore").read_text(encoding="utf-8")
agent_md = (seed_dir / "AGENT.md").read_text(encoding="utf-8")
assert "__pycache__/" in gitignore
assert "*.py[cod]" in gitignore
assert "git status --short" in agent_md
assert "Never push to `main`." in agent_md
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
captured: dict[str, object] = {}
original_run = module.run

def fake_run(cmd, **kwargs):
    captured["cmd"] = cmd
    captured["kwargs"] = kwargs
    return subprocess.CompletedProcess(cmd, 0, "", "")

module.run = fake_run
module.docker_exec("container-123", "printf '%s\\n' \"$OPENAI_API_KEY\"", timeout_seconds=17)
wrapped = captured["cmd"][-1]
assert "set -a" in wrapped
assert "/state/bootstrap/ollama-gate-defaults.env" in wrapped
assert ". " in wrapped
assert "printf '%s\\n' \"$OPENAI_API_KEY\"" in wrapped
module.run = original_run

import os
previous_default_model = os.environ.get("AGENTIC_DEFAULT_MODEL")
os.environ["AGENTIC_DEFAULT_MODEL"] = "test-warm-model:1b"
module.run = fake_run
warmup_ok, warmup_detail = module.warm_default_model(artifact_root / "warmup-proof", timeout_seconds=77)
assert warmup_ok is True
assert warmup_detail == "model warmup completed for test-warm-model:1b"
assert captured["cmd"] == [str(repo_root / "deployments" / "ollama" / "smoke_generate.sh")]
warmup_env = captured["kwargs"]["env"]
assert warmup_env["OLLAMA_API_URL"] == "http://127.0.0.1:11434"
assert warmup_env["OLLAMA_SMOKE_TIMEOUT_SECONDS"] == "77"
assert warmup_env["OLLAMA_SMOKE_MODEL"] == "test-warm-model:1b"
module.run = original_run
if previous_default_model is None:
    os.environ.pop("AGENTIC_DEFAULT_MODEL", None)
else:
    os.environ["AGENTIC_DEFAULT_MODEL"] = previous_default_model

http_calls: list[tuple[str, str, object | None, int]] = []
http_responses = iter(
    [
        {"id": "task-1"},
        [{"status": "WORKING"}],
        [{"status": "READY", "app_conversation_id": "conversation-1"}],
        {"success": True},
        urllib.error.HTTPError(
            "http://127.0.0.1:3000/api/v1/conversation/conversation-1/events/search?limit=100",
            500,
            "Internal Server Error",
            {},
            None,
        ),
        {"items": [{"key": "execution_status", "value": "running"}]},
        {"items": [{"key": "execution_status", "value": "finished"}]},
    ]
)
original_http_json_request = module.http_json_request

def fake_http_json_request(url, *, method="GET", payload=None, timeout=30, headers=None):
    http_calls.append((url, method, payload, timeout))
    response = next(http_responses)
    if isinstance(response, Exception):
        raise response
    return response

module.http_json_request = fake_http_json_request
openhands_ok, openhands_detail = module.invoke_openhands(
    "Solve the repository task and stop.",
    artifact_root / "openhands-proof",
    timeout_seconds=17,
)
assert openhands_ok is True
assert openhands_detail == "openhands conversation finished"
assert http_calls[0][0].endswith("/api/v1/app-conversations")
assert http_calls[0][1] == "POST"
assert http_calls[0][2] == {"title": http_calls[0][2]["title"], "agent_type": "default"}
assert http_calls[1][0].endswith("/api/v1/app-conversations/start-tasks?ids=task-1")
assert http_calls[3][0].endswith("/api/conversations/conversation-1/message")
assert http_calls[3][2] == {"message": "Solve the repository task and stop."}
assert http_calls[4][0].endswith("/api/v1/conversation/conversation-1/events/search?limit=100")
invoke_payload = json.loads((artifact_root / "openhands-proof" / "invoke.stdout.log").read_text(encoding="utf-8"))
assert invoke_payload["conversation_id"] == "conversation-1"
assert invoke_payload["message_response"]["success"] is True
module.http_json_request = original_http_json_request

module.git_forge_api_request = lambda *args, **kwargs: {"name": "eight-queens-agent-e2e"}
module.read_secret = lambda secret_name: "dummy"

clone_url = origin_dir.as_uri()
internal_clone_url = "http://optional-forgejo:3000/agentic/eight-queens-agent-e2e.git"
state = {
    "host_url": "http://127.0.0.1:13010",
    "admin_user": "system-manager",
    "shared_namespace": "agentic",
    "reference_repository": "eight-queens-agent-e2e",
    "reference_clone_url_internal": internal_clone_url,
    "reference_clone_url_host": clone_url,
}
selected_agents = ["codex", "goose"]

skipped = module.reset_agent_branches_if_requested(
    state=state,
    repo_name="eight-queens-agent-e2e",
    clone_url=internal_clone_url,
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
    clone_url=internal_clone_url,
    selected_agents=selected_agents,
    artifact_root=artifact_root / "planned",
    reset_agent_branches=True,
    dry_run=True,
)
assert planned["status"] == "planned"
assert planned["preflight_clone_url"] == clone_url

completed = module.reset_agent_branches_if_requested(
    state=state,
    repo_name="eight-queens-agent-e2e",
    clone_url=internal_clone_url,
    selected_agents=selected_agents,
    artifact_root=artifact_root / "completed",
    reset_agent_branches=True,
    dry_run=False,
)
assert completed["status"] == "completed"
assert completed["preflight_clone_url"] == clone_url
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

attempt_results = [
    {"attempt": 1, "status": "failed", "category": "functional", "stage": "verify", "detail": "pytest exit=1"},
    {"attempt": 2, "status": "success", "category": "success", "stage": "publish", "detail": "agent committed and pushed branch update"},
    {"attempt": 3, "status": "failed", "category": "git", "stage": "publish", "detail": "git publish contract failed exit=1"},
    {"attempt": 4, "status": "failed", "category": "invocation_agent", "stage": "invoke", "detail": "invoke failed exit=1"},
    {"attempt": 5, "status": "failed", "category": "functional", "stage": "verify", "detail": "pytest exit=1"},
]
summary = module.build_agent_result(
    "codex",
    clone_url=internal_clone_url,
    repo_name="eight-queens-agent-e2e",
    root_artifact_dir=artifact_root / "aggregate",
    attempt_results=attempt_results,
    attempts_requested=5,
)
assert summary["status"] == "success"
assert summary["category"] == "success"
assert summary["attempt_statistics"]["requested"] == 5
assert summary["attempt_statistics"]["successes"] == 1
assert summary["attempt_statistics"]["failures"] == 4
assert summary["attempt_statistics"]["successful_attempts"] == [2]
assert summary["validation_policy"] == "at_least_one_success"
assert summary["success_threshold"] == 1

failed_summary = module.build_agent_result(
    "goose",
    clone_url=internal_clone_url,
    repo_name="eight-queens-agent-e2e",
    root_artifact_dir=artifact_root / "aggregate-failed",
    attempt_results=[
        {"attempt": 1, "status": "failed", "category": "functional", "stage": "verify", "detail": "pytest exit=1"},
        {"attempt": 2, "status": "failed", "category": "git", "stage": "publish", "detail": "git publish contract failed exit=1"},
        {"attempt": 3, "status": "failed", "category": "functional", "stage": "verify", "detail": "pytest exit=1"},
        {"attempt": 4, "status": "failed", "category": "functional", "stage": "verify", "detail": "pytest exit=1"},
        {"attempt": 5, "status": "failed", "category": "functional", "stage": "verify", "detail": "pytest exit=1"},
    ],
    attempts_requested=5,
)
assert failed_summary["status"] == "failed"
assert failed_summary["attempt_statistics"]["successes"] == 0
assert failed_summary["category"] == "functional"
assert failed_summary["stage"] == "aggregate"
PY

ok "K12_agent_repo_e2e passed"
