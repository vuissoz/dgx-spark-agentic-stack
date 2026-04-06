#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


AGENTIC_ROOT = pathlib.Path(os.environ.get("AGENTIC_ROOT", "/srv/agentic"))
AGENTIC_COMPOSE_PROJECT = os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic")
BOOTSTRAP_STATE = AGENTIC_ROOT / "optional" / "git" / "bootstrap" / "git-forge-bootstrap.json"
DEFAULT_ARTIFACTS_ROOT = AGENTIC_ROOT / "deployments" / "validation" / "agent-repo-e2e"
OPENHANDS_HOST_PORT = os.environ.get("OPENHANDS_HOST_PORT", "3000")
REFERENCE_PROBLEM_FILE = "src/eight_queens.py"
REFERENCE_PROBLEM_SENTINEL = 'raise NotImplementedError("Implement solve_eight_queens()")'
GIT_FORGE_SECRET_DIR = AGENTIC_ROOT / "secrets" / "runtime" / "git-forge"
PYTEST_IMPORT_CHECK = "python3 -c 'import pytest' >/dev/null"
AGENT_DEFAULTS_FILE = "/state/bootstrap/ollama-gate-defaults.env"

AGENT_MATRIX = {
    "codex": {"service": "agentic-codex", "branch": "agent/codex", "mode": "codex"},
    "openclaw": {"service": "openclaw", "branch": "agent/openclaw", "mode": "openclaw"},
    "claude": {"service": "agentic-claude", "branch": "agent/claude", "mode": "claude"},
    "opencode": {"service": "agentic-opencode", "branch": "agent/opencode", "mode": "opencode"},
    "openhands": {"service": "openhands", "branch": "agent/openhands", "mode": "openhands"},
    "pi-mono": {"service": "optional-pi-mono", "branch": "agent/pi-mono", "mode": "pi"},
    "goose": {"service": "optional-goose", "branch": "agent/goose", "mode": "goose"},
    "vibestral": {"service": "agentic-vibestral", "branch": "agent/vibestral", "mode": "vibe"},
}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def run(
    cmd: list[str],
    *,
    check: bool = True,
    cwd: pathlib.Path | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        text=True,
        capture_output=True,
        cwd=str(cwd) if cwd is not None else None,
        env=env,
        check=check,
    )


def read_secret(secret_name: str) -> str:
    secret_path = GIT_FORGE_SECRET_DIR / f"{secret_name}.password"
    if not secret_path.is_file():
        fail(f"git-forge secret is missing: {secret_path}")
    return secret_path.read_text(encoding="utf-8").strip()


def git_run(
    args: list[str],
    *,
    cwd: pathlib.Path | None = None,
    username: str = "",
    password: str = "",
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"
    if username and password:
        with tempfile.TemporaryDirectory(prefix="agent-repo-e2e-git-") as temp_dir:
            askpass_path = pathlib.Path(temp_dir) / "askpass.sh"
            askpass_path.write_text(
                "#!/bin/sh\n"
                "case \"$1\" in\n"
                "  *Username*|*username*) printf '%s\\n' \"$GIT_USERNAME\" ;;\n"
                "  *Password*|*password*) printf '%s\\n' \"$GIT_PASSWORD\" ;;\n"
                "  *) printf '%s\\n' \"$GIT_PASSWORD\" ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            askpass_path.chmod(0o700)
            env["GIT_ASKPASS"] = str(askpass_path)
            env["GIT_USERNAME"] = username
            env["GIT_PASSWORD"] = password
            return run(["git", *args], cwd=cwd, env=env, check=check)
    return run(["git", *args], cwd=cwd, env=env, check=check)


def load_bootstrap_state() -> dict[str, object]:
    if not BOOTSTRAP_STATE.is_file():
        fail(f"git-forge bootstrap state file is missing: {BOOTSTRAP_STATE}")
    return json.loads(BOOTSTRAP_STATE.read_text(encoding="utf-8"))


def reference_repo_api_path(shared_namespace: str, repository: str) -> str:
    return f"/api/v1/repos/{urllib.parse.quote(shared_namespace)}/{urllib.parse.quote(repository)}"


def service_container_id(service: str) -> str:
    proc = run(
        [
            "docker",
            "ps",
            "--filter",
            f"label=com.docker.compose.project={AGENTIC_COMPOSE_PROJECT}",
            "--filter",
            f"label=com.docker.compose.service={service}",
            "--format",
            "{{.ID}}",
        ]
    )
    return proc.stdout.strip().splitlines()[0] if proc.stdout.strip() else ""


def docker_exec(container_id: str, shell_command: str, *, timeout_seconds: int) -> subprocess.CompletedProcess[str]:
    wrapped_command = (
        f'if [ -f {shlex.quote(AGENT_DEFAULTS_FILE)} ]; then\n'
        f"  set -a\n"
        f"  . {shlex.quote(AGENT_DEFAULTS_FILE)}\n"
        f"  set +a\n"
        f"fi\n"
        f"{shell_command}"
    )
    return run(
        ["timeout", str(timeout_seconds), "docker", "exec", container_id, "sh", "-lc", wrapped_command],
        check=False,
    )


def sanitize_name(value: str) -> str:
    cleaned = []
    for char in value:
        if char.isalnum() or char in ("-", "_"):
            cleaned.append(char)
        else:
            cleaned.append("-")
    return "".join(cleaned).strip("-") or "run"


def build_standard_prompt(repo_name: str, branch: str, workspace: str, mode: str) -> str:
    publish_hint = ""
    if mode == "vibe":
        publish_hint = (
            "The shell is '/bin/sh', so use POSIX-compatible commands only. "
            f"When you publish, run 'git add {REFERENCE_PROBLEM_FILE}', then create the commit with a simple "
            "single-line command such as "
            "'git commit -m \"Implement solve_eight_queens()\"', then push with "
            f"'git push origin HEAD:{branch}'. "
            "Do not use here-strings, heredocs, or shell redirections to build the commit command. "
        )
    return (
        "Read the repository itself before making changes. "
        f"The checked out repository is '{repo_name}' in {workspace} on branch '{branch}'. "
        f"Start by running 'git pull --ff-only origin {branch}' yourself. "
        "Follow the repository instructions, implement the Python fix, and run the documented tests. "
        f"{publish_hint}"
        f"After the tests pass, create a commit on '{branch}' and push it yourself with 'git push origin HEAD:{branch}'. "
        "Finish by writing a concise run summary. Do not ask for clarification. "
        "Leave a clean worktree with local HEAD matching origin after your push. "
        "Do not push to main."
    )


def prepare_workspace(
    container_id: str,
    *,
    clone_url: str,
    workspace: str,
    branch: str,
    timeout_seconds: int,
) -> subprocess.CompletedProcess[str]:
    command = "set -eu\n" + "\n".join(
        [
            f"rm -rf {shlex.quote(workspace)}",
            f"git clone {shlex.quote(clone_url)} {shlex.quote(workspace)}",
            f"cd {shlex.quote(workspace)}",
            f"git checkout -B {shlex.quote(branch)} origin/{shlex.quote(branch)}",
            "git reset --hard HEAD",
            "git clean -fd",
        ]
    )
    return docker_exec(container_id, command, timeout_seconds=timeout_seconds)


def collect_git_artifacts(container_id: str, workspace: str, artifact_dir: pathlib.Path) -> None:
    commands = {
        "git.status": f"cd {shlex.quote(workspace)} && git status --short",
        "git.diff.patch": f"cd {shlex.quote(workspace)} && git diff --binary",
        "git.head": f"cd {shlex.quote(workspace)} && git rev-parse HEAD",
        "git.branch": f"cd {shlex.quote(workspace)} && git rev-parse --abbrev-ref HEAD",
        "git.last-commit": f"cd {shlex.quote(workspace)} && git log -1 --pretty=fuller",
    }
    for filename, shell_command in commands.items():
        proc = docker_exec(container_id, shell_command, timeout_seconds=30)
        (artifact_dir / filename).write_text(proc.stdout, encoding="utf-8")


def resolve_remote_head(
    clone_url: str,
    branch: str,
    *,
    username: str = "",
    password: str = "",
) -> str:
    proc = git_run(["ls-remote", "--heads", clone_url, branch], username=username, password=password)
    line = proc.stdout.strip().splitlines()
    if not line:
        return ""
    return line[0].split()[0]


def verify_unresolved_workspace(
    container_id: str,
    workspace: str,
    branch: str,
    expected_head: str,
    artifact_dir: pathlib.Path,
    timeout_seconds: int,
) -> tuple[bool, str]:
    command = "set -eu\n" + "\n".join(
        [
            f"cd {shlex.quote(workspace)}",
            f"expected_branch={shlex.quote(branch)}",
            f"expected_head={shlex.quote(expected_head)}",
            "current_branch=\"$(git rev-parse --abbrev-ref HEAD)\"",
            "current_head=\"$(git rev-parse HEAD)\"",
            "[ \"$current_branch\" = \"$expected_branch\" ]",
            "[ \"$current_head\" = \"$expected_head\" ]",
            f"grep -F {shlex.quote(REFERENCE_PROBLEM_SENTINEL)} {shlex.quote(REFERENCE_PROBLEM_FILE)} >/dev/null",
            PYTEST_IMPORT_CHECK,
            "if python3 -m pytest -q; then",
            "  echo 'expected unresolved baseline tests to fail before agent work' >&2",
            "  exit 1",
            "fi",
        ]
    )
    proc = docker_exec(container_id, command, timeout_seconds=timeout_seconds)
    (artifact_dir / "baseline.stdout.log").write_text(proc.stdout, encoding="utf-8")
    (artifact_dir / "baseline.stderr.log").write_text(proc.stderr, encoding="utf-8")
    if proc.returncode == 0:
        return True, "prepared branch matches reset baseline and is still unresolved"
    return False, f"prepared branch is not the expected unresolved baseline exit={proc.returncode}"


def read_git_head(container_id: str, workspace: str, timeout_seconds: int) -> str:
    proc = docker_exec(
        container_id,
        f"cd {shlex.quote(workspace)} && git rev-parse HEAD",
        timeout_seconds=timeout_seconds,
    )
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip().splitlines()[0] if proc.stdout.strip() else ""


def verify_tests(container_id: str, workspace: str, artifact_dir: pathlib.Path, timeout_seconds: int) -> tuple[bool, str]:
    proc = docker_exec(
        container_id,
        f"cd {shlex.quote(workspace)} && {PYTEST_IMPORT_CHECK} && python3 -m pytest -q",
        timeout_seconds=timeout_seconds,
    )
    (artifact_dir / "verify.stdout.log").write_text(proc.stdout, encoding="utf-8")
    (artifact_dir / "verify.stderr.log").write_text(proc.stderr, encoding="utf-8")
    return proc.returncode == 0, f"pytest exit={proc.returncode}"


def verify_branch_publish(
    container_id: str,
    workspace: str,
    branch: str,
    initial_head: str,
    artifact_dir: pathlib.Path,
    timeout_seconds: int,
) -> tuple[bool, str]:
    command = "set -eu\n" + "\n".join(
        [
            f"cd {shlex.quote(workspace)}",
            f"expected_branch={shlex.quote(branch)}",
            f"initial_head={shlex.quote(initial_head)}",
            "git fetch origin \"$expected_branch\"",
            "current_branch=\"$(git rev-parse --abbrev-ref HEAD)\"",
            "local_head=\"$(git rev-parse HEAD)\"",
            "remote_head=\"$(git rev-parse FETCH_HEAD)\"",
            "status_output=\"$(git status --short)\"",
            "printf 'current_branch=%s\\nlocal_head=%s\\nremote_head=%s\\n' \"$current_branch\" \"$local_head\" \"$remote_head\"",
            "git log -1 --pretty=fuller",
            "[ \"$current_branch\" = \"$expected_branch\" ]",
            "[ \"$local_head\" != \"$initial_head\" ]",
            "[ \"$local_head\" = \"$remote_head\" ]",
            "[ -z \"$status_output\" ]",
        ]
    )
    proc = docker_exec(container_id, command, timeout_seconds=timeout_seconds)
    (artifact_dir / "publish.stdout.log").write_text(proc.stdout, encoding="utf-8")
    (artifact_dir / "publish.stderr.log").write_text(proc.stderr, encoding="utf-8")
    if proc.returncode == 0:
        return True, "agent committed and pushed branch update"
    return False, f"git publish contract failed exit={proc.returncode}"


def git_forge_api_request(
    base_url: str,
    path: str,
    *,
    username: str,
    password: str,
) -> object:
    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    req = urllib.request.Request(
        f"{base_url}{path}",
        headers={
            "Authorization": f"Basic {token}",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        payload = response.read().decode("utf-8")
    return json.loads(payload) if payload.strip() else {}


def reset_agent_branches_if_requested(
    *,
    state: dict[str, object],
    repo_name: str,
    clone_url: str,
    selected_agents: list[str],
    artifact_root: pathlib.Path,
    reset_agent_branches: bool,
    dry_run: bool,
) -> dict[str, object]:
    preflight_dir = artifact_root / "_preflight"
    preflight_dir.mkdir(parents=True, exist_ok=True)

    branch_summary = {
        agent_name: {
            "branch": str(AGENT_MATRIX[agent_name]["branch"]),
            "reset_applied": False,
        }
        for agent_name in selected_agents
    }

    if not reset_agent_branches:
        payload = {
            "status": "skipped",
            "reset_agent_branches": False,
            "reference_repository": str(state.get("reference_repository") or ""),
            "main_branch": "main",
            "selected_agents": selected_agents,
            "branches": branch_summary,
        }
        (preflight_dir / "preflight.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return payload

    reference_repo = str(state.get("reference_repository") or "")
    if repo_name != reference_repo:
        fail(
            "--reset-agent-branches only supports the stack-managed reference repository "
            f"'{reference_repo}', got '{repo_name}'"
        )
    reference_clone_url_internal = str(state.get("reference_clone_url_internal") or "")
    reference_clone_url_host = str(state.get("reference_clone_url_host") or "")
    allowed_clone_urls = {
        reference_clone_url_internal,
        reference_clone_url_host,
    }
    if clone_url not in allowed_clone_urls:
        fail(
            "--reset-agent-branches only supports the stack-managed Forgejo clone URL for the reference repository; "
            f"got '{clone_url}'"
        )
    if not reference_clone_url_host:
        fail("git-forge bootstrap state is missing reference_clone_url_host")
    preflight_clone_url = reference_clone_url_host

    if dry_run:
        payload = {
            "status": "planned",
            "reset_agent_branches": True,
            "reference_repository": repo_name,
            "main_branch": "main",
            "preflight_clone_url": preflight_clone_url,
            "selected_agents": selected_agents,
            "branches": branch_summary,
        }
        (preflight_dir / "preflight.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return payload

    admin_user = str(state.get("admin_user") or "")
    if not admin_user:
        fail("git-forge bootstrap state is missing admin_user")
    admin_password = read_secret(admin_user)
    shared_namespace = str(state.get("shared_namespace") or "")
    host_url = str(state.get("host_url") or "")
    if not shared_namespace or not host_url:
        fail("git-forge bootstrap state is missing shared_namespace or host_url")

    repo_api = reference_repo_api_path(shared_namespace, repo_name)
    git_forge_api_request(
        host_url,
        repo_api,
        username=admin_user,
        password=admin_password,
    )

    with tempfile.TemporaryDirectory(prefix="agent-repo-e2e-reference-") as temp_dir:
        repo_dir = pathlib.Path(temp_dir) / repo_name
        git_run(["clone", preflight_clone_url, str(repo_dir)], username=admin_user, password=admin_password)
        git_run(["fetch", "--prune", "origin"], cwd=repo_dir, username=admin_user, password=admin_password)
        git_run(["checkout", "-B", "main", "origin/main"], cwd=repo_dir, username=admin_user, password=admin_password)

        main_head_proc = git_run(["rev-parse", "HEAD"], cwd=repo_dir)
        main_head = main_head_proc.stdout.strip().splitlines()[0] if main_head_proc.stdout.strip() else ""
        if not main_head:
            fail("unable to resolve reference repository main head")

        problem_file = repo_dir / REFERENCE_PROBLEM_FILE
        if not problem_file.is_file():
            fail(f"reference repository main branch is missing {REFERENCE_PROBLEM_FILE}")
        problem_text = problem_file.read_text(encoding="utf-8")
        if REFERENCE_PROBLEM_SENTINEL not in problem_text:
            fail(
                "reference repository main branch no longer matches the problem-only seed; "
                f"expected sentinel in {REFERENCE_PROBLEM_FILE}"
            )

        main_proof = {
            "branch": "main",
            "head": main_head,
            "problem_file": REFERENCE_PROBLEM_FILE,
            "problem_sentinel_present": True,
        }
        (preflight_dir / "reference-main.json").write_text(json.dumps(main_proof, indent=2) + "\n", encoding="utf-8")

        for agent_name in selected_agents:
            branch = str(AGENT_MATRIX[agent_name]["branch"])
            before_head = resolve_remote_head(preflight_clone_url, branch, username=admin_user, password=admin_password)
            entry = branch_summary[agent_name]
            entry["before_head"] = before_head
            entry["main_head"] = main_head

            if reset_agent_branches:
                git_run(["branch", "-f", branch, "main"], cwd=repo_dir)
                git_run(
                    ["push", "--force", "origin", f"refs/heads/{branch}:refs/heads/{branch}"],
                    cwd=repo_dir,
                    username=admin_user,
                    password=admin_password,
                )
                entry["reset_applied"] = True

            after_head = resolve_remote_head(preflight_clone_url, branch, username=admin_user, password=admin_password)
            entry["after_head"] = after_head
            entry["aligned_to_main"] = after_head == main_head
            if reset_agent_branches and not entry["aligned_to_main"]:
                fail(f"remote branch {branch} did not reset to main")

    payload = {
        "status": "completed" if reset_agent_branches else "verified",
        "reset_agent_branches": reset_agent_branches,
        "reference_repository": repo_name,
        "main_branch": "main",
        "preflight_clone_url": preflight_clone_url,
        "selected_agents": selected_agents,
        "branches": branch_summary,
    }
    (preflight_dir / "preflight.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return payload


def build_agent_command(mode: str, workspace: str, prompt: str) -> str | None:
    quoted_workspace = shlex.quote(workspace)
    quoted_prompt = shlex.quote(prompt)
    if mode == "codex":
        return (
            f"cd {quoted_workspace} && "
            "codex -a never -s workspace-write exec "
            "--skip-git-repo-check --color never "
            f"{quoted_prompt}"
        )
    if mode == "claude":
        return (
            f"cd {quoted_workspace} && "
            "claude -p --output-format json --permission-mode bypassPermissions "
            "--dangerously-skip-permissions "
            f"{quoted_prompt}"
        )
    if mode == "opencode":
        return f"cd {quoted_workspace} && opencode run --format json --dir {quoted_workspace} {quoted_prompt}"
    if mode == "vibe":
        return f"cd {quoted_workspace} && vibe -p {quoted_prompt} --output json --workdir {quoted_workspace} --max-turns 40"
    if mode == "pi":
        return f"cd {quoted_workspace} && pi -p {quoted_prompt}"
    if mode == "goose":
        return f"cd {quoted_workspace} && goose run --no-session -t {quoted_prompt}"
    if mode == "openclaw":
        return None
    return None


def invoke_openhands(prompt: str, artifact_dir: pathlib.Path, timeout_seconds: int) -> tuple[bool, str]:
    base = f"http://127.0.0.1:{OPENHANDS_HOST_PORT}"
    payload = {
        "title": f"agent-repo-e2e-{int(time.time())}",
        "agent_type": "default",
        "initial_message": {
            "role": "user",
            "content": [{"type": "text", "text": prompt}],
            "run": True,
        },
    }
    req = urllib.request.Request(
        f"{base}/api/v1/app-conversations",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        return False, f"openhands create conversation failed: {exc}"

    task_id = body.get("id")
    if not isinstance(task_id, str) or not task_id:
        return False, f"openhands returned no start-task id: {body}"

    deadline = time.time() + timeout_seconds
    last_payload: object = body
    while time.time() < deadline:
        with urllib.request.urlopen(
            f"{base}/api/v1/app-conversations/start-tasks?ids={urllib.parse.quote(task_id)}",
            timeout=30,
        ) as resp:
            tasks = json.loads(resp.read().decode("utf-8"))
        last_payload = tasks
        if isinstance(tasks, list) and tasks:
            state = tasks[0] or {}
            status = state.get("status")
            if status == "READY":
                break
            if status == "ERROR":
                return False, f"openhands start-task failed: {state}"
        time.sleep(2)
    else:
        return False, "openhands start-task timed out"

    (artifact_dir / "invoke.stdout.log").write_text(json.dumps(last_payload, indent=2) + "\n", encoding="utf-8")
    (artifact_dir / "invoke.stderr.log").write_text("", encoding="utf-8")
    return True, "openhands conversation started"


def classify_result(
    *,
    stage: str,
    ok: bool,
    detail: str,
    unsupported: bool = False,
) -> dict[str, object]:
    if ok:
        status = "success"
        category = "success"
    elif unsupported:
        status = "failed"
        category = "invocation_agent"
    elif stage in {"prepare", "checkout"}:
        status = "failed"
        category = "checkout"
    elif stage == "baseline":
        status = "failed"
        category = "functional"
    elif stage == "invoke":
        status = "failed"
        category = "invocation_agent"
    elif stage == "verify":
        status = "failed"
        category = "functional"
    elif stage == "publish":
        status = "failed"
        category = "git"
    else:
        status = "failed"
        category = "infra"
    return {"status": status, "category": category, "stage": stage, "detail": detail}


def run_agent(
    agent_name: str,
    *,
    clone_url: str,
    repo_name: str,
    root_artifact_dir: pathlib.Path,
    prepare_timeout: int,
    invoke_timeout: int,
    verify_timeout: int,
    dry_run: bool,
    require_unresolved_baseline: bool,
    expected_initial_head: str,
) -> dict[str, object]:
    config = AGENT_MATRIX[agent_name]
    artifact_dir = root_artifact_dir / agent_name
    artifact_dir.mkdir(parents=True, exist_ok=True)

    service = str(config["service"])
    branch = str(config["branch"])
    mode = str(config["mode"])
    workspace = f"/workspace/{sanitize_name(repo_name)}-{sanitize_name(agent_name)}"
    prompt = build_standard_prompt(repo_name, branch, workspace, mode)

    result: dict[str, object] = {
        "agent": agent_name,
        "service": service,
        "branch": branch,
        "workspace": workspace,
        "mode": mode,
        "artifacts_dir": str(artifact_dir),
    }

    plan_payload = {
        "clone_url": clone_url,
        "workspace": workspace,
        "branch": branch,
        "mode": mode,
        "prompt": prompt,
    }
    (artifact_dir / "plan.json").write_text(json.dumps(plan_payload, indent=2) + "\n", encoding="utf-8")

    if dry_run:
        result.update({"status": "planned", "category": "planned", "stage": "plan", "detail": "dry-run only"})
        return result

    container_id = service_container_id(service)
    if not container_id:
        result.update(classify_result(stage="prepare", ok=False, detail=f"service not running: {service}"))
        return result
    result["container_id"] = container_id

    prepare = prepare_workspace(
        container_id,
        clone_url=clone_url,
        workspace=workspace,
        branch=branch,
        timeout_seconds=prepare_timeout,
    )
    (artifact_dir / "prepare.stdout.log").write_text(prepare.stdout, encoding="utf-8")
    (artifact_dir / "prepare.stderr.log").write_text(prepare.stderr, encoding="utf-8")
    if prepare.returncode != 0:
        result.update(classify_result(stage="checkout", ok=False, detail=f"prepare failed exit={prepare.returncode}"))
        return result
    initial_head = read_git_head(container_id, workspace, 30)
    if not initial_head:
        result.update(classify_result(stage="checkout", ok=False, detail="unable to resolve initial branch head"))
        return result
    if expected_initial_head and initial_head != expected_initial_head:
        result.update(
            classify_result(
                stage="checkout",
                ok=False,
                detail=(
                    f"prepared branch head {initial_head} does not match expected reset baseline "
                    f"{expected_initial_head}"
                ),
            )
        )
        return result
    result["initial_head"] = initial_head

    if require_unresolved_baseline:
        baseline_ok, baseline_detail = verify_unresolved_workspace(
            container_id,
            workspace,
            branch,
            initial_head,
            artifact_dir,
            verify_timeout,
        )
        if not baseline_ok:
            collect_git_artifacts(container_id, workspace, artifact_dir)
            result.update(classify_result(stage="baseline", ok=False, detail=baseline_detail))
            return result
        result["baseline_detail"] = baseline_detail

    if mode == "openhands":
        ok, detail = invoke_openhands(prompt, artifact_dir, invoke_timeout)
        if not ok:
            result.update(classify_result(stage="invoke", ok=False, detail=detail))
            return result
    else:
        command = build_agent_command(mode, workspace, prompt)
        if command is None:
            result.update(
                classify_result(
                    stage="invoke",
                    ok=False,
                    detail=f"no non-interactive adapter implemented for mode={mode}",
                    unsupported=True,
                )
            )
            return result
        invoke = docker_exec(container_id, command, timeout_seconds=invoke_timeout)
        (artifact_dir / "invoke.stdout.log").write_text(invoke.stdout, encoding="utf-8")
        (artifact_dir / "invoke.stderr.log").write_text(invoke.stderr, encoding="utf-8")
        if invoke.returncode != 0:
            result.update(classify_result(stage="invoke", ok=False, detail=f"invoke failed exit={invoke.returncode}"))
            return result

    tests_ok, tests_detail = verify_tests(container_id, workspace, artifact_dir, verify_timeout)
    collect_git_artifacts(container_id, workspace, artifact_dir)
    if not tests_ok:
        result.update(classify_result(stage="verify", ok=False, detail=tests_detail))
        return result

    publish_ok, publish_detail = verify_branch_publish(
        container_id,
        workspace,
        branch,
        initial_head,
        artifact_dir,
        verify_timeout,
    )
    collect_git_artifacts(container_id, workspace, artifact_dir)
    result.update(classify_result(stage="publish", ok=publish_ok, detail=publish_detail))
    return result


def build_final_doctor(results: list[dict[str, object]]) -> dict[str, object]:
    counts: dict[str, int] = {}
    for result in results:
        category = str(result.get("category", "infra"))
        counts[category] = counts.get(category, 0) + 1

    if counts.get("success", 0) == len(results):
        overall = "success"
    elif counts.get("infra", 0):
        overall = "failed"
    else:
        overall = "partial"

    return {
        "overall": overall,
        "counts": counts,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "required_agents": list(AGENT_MATRIX),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Repository-driven multi-agent E2E runner")
    parser.add_argument("--agents", default=",".join(AGENT_MATRIX), help="Comma-separated agent list")
    parser.add_argument("--repo", default="", help="Repository name override")
    parser.add_argument("--clone-url", default="", help="Internal clone URL override")
    parser.add_argument("--artifacts-dir", default="", help="Artifacts directory override")
    parser.add_argument("--prepare-timeout", type=int, default=120)
    parser.add_argument("--invoke-timeout", type=int, default=900)
    parser.add_argument("--verify-timeout", type=int, default=180)
    parser.add_argument(
        "--reset-agent-branches",
        action="store_true",
        help="Destructively realign selected remote agent/<tool> branches to main before the run",
    )
    parser.add_argument("--dry-run", action="store_true", help="Resolve plan and artifacts without invoking agents")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    state = load_bootstrap_state()
    repo_name = args.repo or str(state.get("reference_repository") or "")
    clone_url = args.clone_url or str(state.get("reference_clone_url_internal") or "")
    if not repo_name or not clone_url:
        fail("reference repository metadata is missing from git-forge bootstrap state")

    selected_agents = [item.strip() for item in args.agents.split(",") if item.strip()]
    for agent_name in selected_agents:
        if agent_name not in AGENT_MATRIX:
            fail(f"unknown agent '{agent_name}'")

    timestamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    artifact_root = pathlib.Path(args.artifacts_dir) if args.artifacts_dir else DEFAULT_ARTIFACTS_ROOT / timestamp
    artifact_root.mkdir(parents=True, exist_ok=True)

    preflight = reset_agent_branches_if_requested(
        state=state,
        repo_name=repo_name,
        clone_url=clone_url,
        selected_agents=selected_agents,
        artifact_root=artifact_root,
        reset_agent_branches=args.reset_agent_branches,
        dry_run=args.dry_run,
    )

    expected_heads = {
        agent_name: str((preflight.get("branches") or {}).get(agent_name, {}).get("after_head") or "")
        for agent_name in selected_agents
    }

    results = [
        run_agent(
            agent_name,
            clone_url=clone_url,
            repo_name=repo_name,
            root_artifact_dir=artifact_root,
            prepare_timeout=args.prepare_timeout,
            invoke_timeout=args.invoke_timeout,
            verify_timeout=args.verify_timeout,
            dry_run=args.dry_run,
            require_unresolved_baseline=args.reset_agent_branches,
            expected_initial_head=expected_heads.get(agent_name, ""),
        )
        for agent_name in selected_agents
    ]
    doctor = build_final_doctor(results)

    (artifact_root / "summary.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    (artifact_root / "doctor.json").write_text(json.dumps(doctor, indent=2) + "\n", encoding="utf-8")

    print(
        json.dumps(
            {"artifacts_dir": str(artifact_root), "preflight": preflight, "results": results, "doctor": doctor},
            indent=2,
        )
    )
    if doctor["overall"] not in ("success", "partial") and not args.dry_run:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
