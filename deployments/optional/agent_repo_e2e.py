#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import pathlib
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


AGENTIC_ROOT = pathlib.Path(os.environ.get("AGENTIC_ROOT", "/srv/agentic"))
AGENTIC_COMPOSE_PROJECT = os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic")
BOOTSTRAP_STATE = AGENTIC_ROOT / "optional" / "git" / "bootstrap" / "git-forge-bootstrap.json"
DEFAULT_ARTIFACTS_ROOT = AGENTIC_ROOT / "deployments" / "validation" / "agent-repo-e2e"
OPENHANDS_HOST_PORT = os.environ.get("OPENHANDS_HOST_PORT", "3000")

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


def load_bootstrap_state() -> dict[str, object]:
    if not BOOTSTRAP_STATE.is_file():
        fail(f"git-forge bootstrap state file is missing: {BOOTSTRAP_STATE}")
    return json.loads(BOOTSTRAP_STATE.read_text(encoding="utf-8"))


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
    return run(
        ["timeout", str(timeout_seconds), "docker", "exec", container_id, "sh", "-lc", shell_command],
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


def build_standard_prompt(repo_name: str, branch: str, workspace: str) -> str:
    return (
        "Read the repository itself before making changes. "
        f"The checked out repository is '{repo_name}' in {workspace} on branch '{branch}'. "
        "Follow the repository instructions, implement the Python fix, run the documented tests, "
        "and finish by writing a concise run summary. Do not ask for clarification. "
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
    }
    for filename, shell_command in commands.items():
        proc = docker_exec(container_id, shell_command, timeout_seconds=30)
        (artifact_dir / filename).write_text(proc.stdout, encoding="utf-8")


def verify_tests(container_id: str, workspace: str, artifact_dir: pathlib.Path, timeout_seconds: int) -> tuple[bool, str]:
    proc = docker_exec(
        container_id,
        f"cd {shlex.quote(workspace)} && python3 -m pytest -q",
        timeout_seconds=timeout_seconds,
    )
    (artifact_dir / "verify.stdout.log").write_text(proc.stdout, encoding="utf-8")
    (artifact_dir / "verify.stderr.log").write_text(proc.stderr, encoding="utf-8")
    return proc.returncode == 0, f"pytest exit={proc.returncode}"


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
    elif stage == "invoke":
        status = "failed"
        category = "invocation_agent"
    elif stage == "verify":
        status = "failed"
        category = "functional"
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
) -> dict[str, object]:
    config = AGENT_MATRIX[agent_name]
    artifact_dir = root_artifact_dir / agent_name
    artifact_dir.mkdir(parents=True, exist_ok=True)

    service = str(config["service"])
    branch = str(config["branch"])
    mode = str(config["mode"])
    workspace = f"/workspace/{sanitize_name(repo_name)}-{sanitize_name(agent_name)}"
    prompt = build_standard_prompt(repo_name, branch, workspace)

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
    result.update(classify_result(stage="verify", ok=tests_ok, detail=tests_detail))
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
        )
        for agent_name in selected_agents
    ]
    doctor = build_final_doctor(results)

    (artifact_root / "summary.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    (artifact_root / "doctor.json").write_text(json.dumps(doctor, indent=2) + "\n", encoding="utf-8")

    print(json.dumps({"artifacts_dir": str(artifact_root), "results": results, "doctor": doctor}, indent=2))
    if doctor["overall"] not in ("success", "partial") and not args.dry_run:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
