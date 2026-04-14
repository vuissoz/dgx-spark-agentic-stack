#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse


SERVICE_NAME = "optional-forgejo"
SHARED_TEAM = "agents"
SHARED_REPOSITORY = os.environ.get("GIT_FORGE_SHARED_REPOSITORY", "shared-workbench")
REFERENCE_REPOSITORY = os.environ.get("GIT_FORGE_REFERENCE_REPOSITORY", "eight-queens-agent-e2e")
AGENTIC_ROOT = os.environ.get("AGENTIC_ROOT", "/srv/agentic")
AGENTIC_COMPOSE_PROJECT = os.environ.get("AGENTIC_COMPOSE_PROJECT", "compose")
AGENTIC_NETWORK = os.environ.get("AGENTIC_NETWORK", "agentic")
AGENT_RUNTIME_UID = int(os.environ.get("AGENT_RUNTIME_UID", "1000"))
AGENT_RUNTIME_GID = int(os.environ.get("AGENT_RUNTIME_GID", "1000"))
GIT_FORGE_HOST_PORT = os.environ.get("GIT_FORGE_HOST_PORT", "13010")
GIT_FORGE_ADMIN_USER = os.environ.get("GIT_FORGE_ADMIN_USER", "system-manager")
GIT_FORGE_SHARED_NAMESPACE = os.environ.get("GIT_FORGE_SHARED_NAMESPACE", "agentic")
GIT_FORGE_INTERNAL_HOST = os.environ.get("GIT_FORGE_INTERNAL_HOST", SERVICE_NAME)
GIT_FORGE_INTERNAL_HTTP_PORT = os.environ.get("GIT_FORGE_INTERNAL_HTTP_PORT", "3000")
GIT_FORGE_INTERNAL_SSH_PORT = os.environ.get("GIT_FORGE_INTERNAL_SSH_PORT", "2222")
GIT_FORGE_ALLOW_PROJECT_FALLBACK = os.environ.get("AGENTIC_GIT_FORGE_ALLOW_PROJECT_FALLBACK", "0")
HOST_BASE_URL = f"http://127.0.0.1:{GIT_FORGE_HOST_PORT}"
INTERNAL_BASE_URL = f"http://{GIT_FORGE_INTERNAL_HOST}:{GIT_FORGE_INTERNAL_HTTP_PORT}"
GIT_HELPER_IMAGE = os.environ.get("AGENTIC_GIT_FORGE_GIT_HELPER_IMAGE", "ghcr.io/nicolaka/netshoot:latest")
SECRETS_ROOT = pathlib.Path(AGENTIC_ROOT) / "secrets" / "runtime" / "git-forge"
BOOTSTRAP_DIR = pathlib.Path(AGENTIC_ROOT) / "optional" / "git" / "bootstrap"
REFERENCE_TEMPLATE_DIR = pathlib.Path(__file__).resolve().parents[2] / "examples" / "optional" / REFERENCE_REPOSITORY
REFERENCE_MANIFEST_PATH = ".agentic/reference-e2e.manifest.json"

MANAGED_ACCOUNTS = (
    {
        "username": "openclaw",
        "display_name": "OpenClaw",
        "email": "openclaw@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "openclaw" / "state" / "cli" / "openclaw-home",
        "container_home": "/state/cli/openclaw-home",
        "container_ssh_dir": "/state/cli/openclaw-home/.ssh",
    },
    {
        "username": "openhands",
        "display_name": "OpenHands",
        "email": "openhands@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "openhands" / "state" / "home",
        "container_home": "/.openhands/home",
        "container_ssh_dir": "/.openhands/home/.ssh",
        "ssh_reader_uids": (42420,),
    },
    {
        "username": "comfyui",
        "display_name": "ComfyUI",
        "email": "comfyui@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "comfyui" / "user",
        "container_home": "/comfyui/user",
        "container_ssh_dir": "/comfyui/user/.ssh",
    },
    {
        "username": "claude",
        "display_name": "Claude",
        "email": "claude@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "claude" / "state" / "home",
        "container_home": "/state/home",
        "container_ssh_dir": "/state/home/.ssh",
    },
    {
        "username": "codex",
        "display_name": "Codex",
        "email": "codex@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "codex" / "state" / "home",
        "container_home": "/state/home",
        "container_ssh_dir": "/state/home/.ssh",
    },
    {
        "username": "opencode",
        "display_name": "OpenCode",
        "email": "opencode@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "opencode" / "state" / "home",
        "container_home": "/state/home",
        "container_ssh_dir": "/state/home/.ssh",
    },
    {
        "username": "vibestral",
        "display_name": "Vibestral",
        "email": "vibestral@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "vibestral" / "state" / "home",
        "container_home": "/state/home",
        "container_ssh_dir": "/state/home/.ssh",
    },
    {
        "username": "hermes",
        "display_name": "Hermes",
        "email": "hermes@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "hermes" / "state" / "home",
        "container_home": "/state/home",
        "container_ssh_dir": "/state/home/.ssh",
    },
    {
        "username": "pi-mono",
        "display_name": "Pi Mono",
        "email": "pi-mono@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "optional" / "pi-mono" / "state" / "home",
        "container_home": "/state/home",
        "container_ssh_dir": "/state/home/.ssh",
    },
    {
        "username": "goose",
        "display_name": "Goose",
        "email": "goose@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "optional" / "goose" / "state" / "home",
        "container_home": "/state/home",
        "container_ssh_dir": "/state/home/.ssh",
    },
)

TEAM_UNITS = [
    "repo.actions",
    "repo.code",
    "repo.issues",
    "repo.projects",
    "repo.pulls",
    "repo.releases",
    "repo.packages",
    "repo.wiki",
]

REFERENCE_AGENT_BRANCHES = tuple(
    f"agent/{name}"
    for name in ("codex", "openclaw", "claude", "opencode", "openhands", "pi-mono", "goose", "vibestral", "hermes")
)


def run(
    cmd: list[str],
    *,
    input_text: str | None = None,
    check: bool = True,
    cwd: pathlib.Path | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        input=input_text,
        text=True,
        capture_output=True,
        check=check,
        cwd=str(cwd) if cwd is not None else None,
        env=env,
    )


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def info(message: str) -> None:
    print(f"INFO: {message}")


def repo_clone_url(base_url: str, repository: str) -> str:
    return f"{base_url}/{GIT_FORGE_SHARED_NAMESPACE}/{repository}.git"


def repo_ssh_url(host: str, port: str, repository: str) -> str:
    return f"ssh://git@{host}:{port}/{GIT_FORGE_SHARED_NAMESPACE}/{repository}"


def repo_api_path(repository: str) -> str:
    return f"/api/v1/repos/{urllib.parse.quote(GIT_FORGE_SHARED_NAMESPACE)}/{urllib.parse.quote(repository)}"


def repo_exists(repository: str, admin_user: str, admin_password: str) -> bool:
    existing = api_request(
        container_id,
        "GET",
        repo_api_path(repository),
        username=admin_user,
        password=admin_password,
        expected=(200,),
        allow_not_found=True,
    )
    return existing is not None


def service_container_id(service_name: str) -> str:
    proc = run(
        [
            "docker",
            "ps",
            "--filter",
            f"label=com.docker.compose.project={AGENTIC_COMPOSE_PROJECT}",
            "--filter",
            f"label=com.docker.compose.service={service_name}",
            "--format",
            "{{.ID}}",
        ]
    )
    if proc.stdout.strip():
        return proc.stdout.strip().splitlines()[0]

    if GIT_FORGE_ALLOW_PROJECT_FALLBACK in {"1", "true", "TRUE", "yes", "YES", "on", "ON"}:
        fallback_project = "compose"
        if AGENTIC_COMPOSE_PROJECT == fallback_project:
            return ""
        proc = run(
            [
                "docker",
                "ps",
                "--filter",
                f"label=com.docker.compose.project={fallback_project}",
                "--filter",
                f"label=com.docker.compose.service={service_name}",
                "--format",
                "{{.ID}}",
            ]
        )
        if proc.stdout.strip():
            return proc.stdout.strip().splitlines()[0]

    return ""


def wait_for_http(container_id: str, timeout_seconds: int = 120) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            docker_exec(
                container_id,
                "wget",
                "-q",
                "-O-",
                "http://127.0.0.1:3000/",
                check=True,
            )
            return
        except Exception:
            time.sleep(1)
            continue
    fail(f"git-forge service did not become reachable inside '{container_id}' within {timeout_seconds}s")


def docker_exec(container_id: str, *args: str, input_text: str | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run(["docker", "exec", "-i", container_id, *args], input_text=input_text, check=check)


def list_users(container_id: str) -> dict[str, dict[str, str]]:
    proc = docker_exec(container_id, "forgejo", "admin", "user", "list")
    users: dict[str, dict[str, str]] = {}
    for line in proc.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 6:
            continue
        users[parts[1]] = {
            "email": parts[2],
            "is_admin": parts[4].lower(),
        }
    return users


def ensure_user(container_id: str, username: str, email: str, password: str, *, admin: bool) -> None:
    users = list_users(container_id)
    if username not in users:
        cmd = (
            "read -r pass; "
            f"exec forgejo admin user create --username {shlex.quote(username)} "
            f"--email {shlex.quote(email)} --password \"$pass\" "
            "--must-change-password=false "
            + ("--admin" if admin else "")
        )
        try:
            docker_exec(container_id, "/bin/bash", "--noprofile", "--norc", "-lc", cmd, input_text=f"{password}\n")
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or exc.stdout or "").strip()
            if "name is reserved" in detail.lower():
                fail(
                    f"forge bootstrap user '{username}' is rejected by Forgejo because the login is reserved; "
                    "set GIT_FORGE_ADMIN_USER to a different value such as 'system-manager' and regenerate runtime secrets"
                )
            fail(
                f"failed to create forge account '{username}': {detail or f'exit status {exc.returncode}'}"
            )
        info(f"created forge account '{username}'")
        return

    if admin and users[username]["is_admin"] != "true":
      fail(f"existing forge account '{username}' is not admin; manual repair is required")

    cmd = (
        "read -r pass; "
        f"exec forgejo admin user change-password --username {shlex.quote(username)} "
        "--password \"$pass\" --must-change-password=false"
    )
    try:
        docker_exec(container_id, "/bin/bash", "--noprofile", "--norc", "-lc", cmd, input_text=f"{password}\n")
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        fail(f"failed to update forge password for '{username}': {detail or f'exit status {exc.returncode}'}")


def clear_must_change_password(container_id: str) -> None:
    try:
        docker_exec(
            container_id,
            "forgejo",
            "admin",
            "user",
            "must-change-password",
            "--unset",
            "--all",
        )
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        fail(f"failed to clear Forgejo must-change-password policy: {detail or f'exit status {exc.returncode}'}")


def read_secret(secret_name: str) -> str:
    secret_path = SECRETS_ROOT / f"{secret_name}.password"
    if not secret_path.is_file():
        fail(f"missing git-forge secret: {secret_path}")
    return secret_path.read_text(encoding="utf-8").strip()


def auth_header(username: str, password: str) -> str:
    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return f"Basic {token}"


def api_request(
    container_id: str,
    method: str,
    path: str,
    *,
    username: str,
    password: str,
    payload: dict[str, object] | None = None,
    expected: tuple[int, ...] = (200, 201, 204),
    allow_not_found: bool = False,
    retried_must_change: bool = False,
) -> object | None:
    payload_text = json.dumps(payload) if payload is not None else ""
    script = r'''
set -eu
path="$1"
method="$2"
auth="$3"
has_payload="$4"
body_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "$body_file" "$response_file"' EXIT
if [ "$has_payload" = "1" ]; then
  cat >"$body_file"
  http_code="$(curl -sS -o "$response_file" -w "%{http_code}" -u "$auth" -H "Accept: application/json" -H "Content-Type: application/json" -X "$method" --data-binary @"$body_file" "http://127.0.0.1:3000${path}")"
else
  http_code="$(curl -sS -o "$response_file" -w "%{http_code}" -u "$auth" -H "Accept: application/json" -X "$method" "http://127.0.0.1:3000${path}")"
fi
printf '%s\n' "$http_code"
cat "$response_file"
'''
    proc = docker_exec(
        container_id,
        "/bin/bash",
        "--noprofile",
        "--norc",
        "-lc",
        script,
        "--",
        path,
        method,
        f"{username}:{password}",
        "1" if payload is not None else "0",
        input_text=payload_text,
        check=False,
    )
    if proc.returncode != 0:
        fail(f"forge API invocation failed for {method} {path}: {proc.stderr.strip() or proc.stdout.strip()}")

    stdout = proc.stdout
    lines = stdout.splitlines()
    status = int(lines[0]) if lines else 0
    body = "\n".join(lines[1:])

    if allow_not_found and status == 404:
        return None
    if status == 403 and not retried_must_change and "must change" in body.lower():
        clear_must_change_password(container_id)
        return api_request(
            container_id,
            method,
            path,
            username=username,
            password=password,
            payload=payload,
            expected=expected,
            allow_not_found=allow_not_found,
            retried_must_change=True,
        )
    if status not in expected:
        fail(f"unexpected forge API status for {method} {path}: {status} {body}".strip())
    if not body.strip():
        return None
    return json.loads(body)


def ensure_org(admin_user: str, admin_password: str) -> None:
    existing = api_request(
        container_id,
        "GET",
        f"/api/v1/orgs/{urllib.parse.quote(GIT_FORGE_SHARED_NAMESPACE)}",
        username=admin_user,
        password=admin_password,
        expected=(200,),
        allow_not_found=True,
    )
    if existing is not None:
        return

    api_request(
        container_id,
        "POST",
        "/api/v1/orgs",
        username=admin_user,
        password=admin_password,
        payload={
            "username": GIT_FORGE_SHARED_NAMESPACE,
            "full_name": "Agentic Shared Projects",
            "description": "Stack-managed shared namespace for agent collaboration",
            "visibility": "private",
            "repo_admin_change_team_access": True,
        },
        expected=(201,),
    )
    info(f"created forge organization '{GIT_FORGE_SHARED_NAMESPACE}'")


def ensure_team(admin_user: str, admin_password: str) -> int:
    result = api_request(
        container_id,
        "GET",
        f"/api/v1/orgs/{urllib.parse.quote(GIT_FORGE_SHARED_NAMESPACE)}/teams/search?q={urllib.parse.quote(SHARED_TEAM)}",
        username=admin_user,
        password=admin_password,
        expected=(200,),
    )
    assert isinstance(result, dict)
    for entry in result.get("data", []):
        if isinstance(entry, dict) and entry.get("name") == SHARED_TEAM and isinstance(entry.get("id"), int):
            permission = str(entry.get("permission", "")).strip().lower()
            if permission != "write":
                api_request(
                    container_id,
                    "PATCH",
                    f"/api/v1/teams/{entry['id']}",
                    username=admin_user,
                    password=admin_password,
                    payload={
                        "name": SHARED_TEAM,
                        "description": "Stack-managed team for agent collaboration",
                        "permission": "write",
                        "can_create_org_repo": True,
                        "includes_all_repositories": True,
                        "units": TEAM_UNITS,
                    },
                    expected=(200, 201),
                )
                info(f"updated forge team '{SHARED_TEAM}' permission to write")
            return int(entry["id"])

    result = api_request(
        container_id,
        "POST",
        f"/api/v1/orgs/{urllib.parse.quote(GIT_FORGE_SHARED_NAMESPACE)}/teams",
        username=admin_user,
        password=admin_password,
        payload={
            "name": SHARED_TEAM,
            "description": "Stack-managed team for agent collaboration",
            "permission": "write",
            "can_create_org_repo": True,
            "includes_all_repositories": True,
            "units": TEAM_UNITS,
        },
        expected=(201,),
    )
    assert isinstance(result, dict) and isinstance(result.get("id"), int)
    info(f"created forge team '{SHARED_TEAM}'")
    return int(result["id"])


def ensure_team_member(team_id: int, username: str, admin_user: str, admin_password: str) -> None:
    existing = api_request(
        container_id,
        "GET",
        f"/api/v1/teams/{team_id}/members/{urllib.parse.quote(username)}",
        username=admin_user,
        password=admin_password,
        expected=(200,),
        allow_not_found=True,
    )
    if existing is not None:
        return

    api_request(
        container_id,
        "PUT",
        f"/api/v1/teams/{team_id}/members/{urllib.parse.quote(username)}",
        username=admin_user,
        password=admin_password,
        expected=(204,),
    )


def ensure_repository(repository: str, description: str, admin_user: str, admin_password: str) -> None:
    if repo_exists(repository, admin_user, admin_password):
        return

    api_request(
        container_id,
        "POST",
        f"/api/v1/orgs/{urllib.parse.quote(GIT_FORGE_SHARED_NAMESPACE)}/repos",
        username=admin_user,
        password=admin_password,
        payload={
            "name": repository,
            "description": description,
            "private": True,
            "auto_init": True,
            "default_branch": "main",
            "readme": "Default",
        },
        expected=(201,),
    )
    info(f"created forge repository '{GIT_FORGE_SHARED_NAMESPACE}/{repository}'")


def ensure_shared_repo(admin_user: str, admin_password: str) -> None:
    ensure_repository(
        SHARED_REPOSITORY,
        "Shared repository for stack-managed collaboration checks",
        admin_user,
        admin_password,
    )


def git_with_askpass(
    args: list[str],
    *,
    username: str,
    password: str,
    cwd: pathlib.Path | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="git-forge-bootstrap-") as temp_dir:
        askpass_path = pathlib.Path(temp_dir) / "askpass.sh"
        askpass_path.write_text(
            "#!/bin/sh\n"
            "case \"$1\" in\n"
            "  *Username*|*username*) printf '%s\\n' \"$GIT_USERNAME\" ;;\n"
            "  *Password*|*password*) printf '%s\\n' \"$GIT_FORGE_PASSWORD\" ;;\n"
            "  *) printf '%s\\n' \"$GIT_FORGE_PASSWORD\" ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        os.chmod(askpass_path, 0o700)
        cmd = [
            "docker",
            "run",
            "--rm",
            "--network",
            AGENTIC_NETWORK,
            "--user",
            f"{os.getuid()}:{os.getgid()}",
            "-e",
            "GIT_ASKPASS=/tmp/git-forge-askpass.sh",
            "-e",
            "GIT_TERMINAL_PROMPT=0",
            "-e",
            f"GIT_USERNAME={username}",
            "-e",
            f"GIT_FORGE_PASSWORD={password}",
            "-v",
            f"{askpass_path}:/tmp/git-forge-askpass.sh:ro",
        ]

        bind_mounts: dict[pathlib.Path, pathlib.Path] = {}
        if cwd is not None:
            bind_mounts[cwd] = cwd
        for arg in args:
            if not os.path.isabs(arg):
                continue
            path = pathlib.Path(arg)
            mount_path = path if path.exists() else path.parent
            bind_mounts[mount_path] = mount_path
        for host_path in sorted(bind_mounts, key=str):
            cmd.extend(["-v", f"{host_path}:{bind_mounts[host_path]}"])

        if cwd is not None:
            cmd.extend(["-w", str(cwd)])

        cmd.extend([GIT_HELPER_IMAGE, "git", *args])
        return run(cmd, check=check)


def sync_reference_template(target_dir: pathlib.Path) -> None:
    if not REFERENCE_TEMPLATE_DIR.is_dir():
        fail(f"reference repository template is missing: {REFERENCE_TEMPLATE_DIR}")

    for entry in target_dir.iterdir():
        if entry.name == ".git":
            continue
        if entry.is_dir():
            shutil.rmtree(entry)
        else:
            entry.unlink()

    for source in REFERENCE_TEMPLATE_DIR.rglob("*"):
        relative = source.relative_to(REFERENCE_TEMPLATE_DIR)
        destination = target_dir / relative
        if source.is_dir():
            destination.mkdir(parents=True, exist_ok=True)
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def repo_is_managed_reference(target_dir: pathlib.Path) -> bool:
    return (target_dir / REFERENCE_MANIFEST_PATH).is_file()


def repo_is_seedable_default(target_dir: pathlib.Path) -> bool:
    proc = run(["git", "ls-files"], cwd=target_dir)
    tracked = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    return tracked in ([], ["README.md"])


def ensure_remote_branch_exists(
    repository_dir: pathlib.Path,
    branch_name: str,
    *,
    username: str,
    password: str,
) -> None:
    proc = git_with_askpass(
        ["ls-remote", "--heads", "origin", branch_name],
        username=username,
        password=password,
        cwd=repository_dir,
    )
    if proc.stdout.strip():
        return

    git_with_askpass(["branch", "-f", branch_name, "main"], username=username, password=password, cwd=repository_dir)
    git_with_askpass(
        ["push", "origin", f"{branch_name}:refs/heads/{branch_name}"],
        username=username,
        password=password,
        cwd=repository_dir,
    )
    info(f"created reference branch '{branch_name}'")


def ensure_main_branch_protection(admin_user: str, admin_password: str) -> None:
    branch_path = (
        f"{repo_api_path(REFERENCE_REPOSITORY)}/branch_protections/"
        f"{urllib.parse.quote('main', safe='')}"
    )
    payload = {
        "branch_name": "main",
        "enable_push": True,
        "enable_push_whitelist": True,
        "push_whitelist_usernames": [GIT_FORGE_ADMIN_USER],
        "enable_merge_whitelist": False,
        "enable_status_check": False,
        "enable_approvals_whitelist": False,
        "required_approvals": 0,
    }
    existing = api_request(
        container_id,
        "GET",
        branch_path,
        username=admin_user,
        password=admin_password,
        expected=(200,),
        allow_not_found=True,
    )
    if existing is None:
        api_request(
            container_id,
            "POST",
            f"{repo_api_path(REFERENCE_REPOSITORY)}/branch_protections",
            username=admin_user,
            password=admin_password,
            payload=payload,
            expected=(201,),
        )
        info("enabled main branch protection for reference repo")
        return

    api_request(
        container_id,
        "PATCH",
        branch_path,
        username=admin_user,
        password=admin_password,
        payload=payload,
        expected=(200, 201),
    )


def seed_reference_repo(admin_user: str, admin_password: str) -> None:
    ensure_repository(
        REFERENCE_REPOSITORY,
        "Stack-managed repository for the repository-driven multi-agent E2E scenario",
        admin_user,
        admin_password,
    )

    with tempfile.TemporaryDirectory(prefix="agentic-reference-repo-") as temp_dir:
        repo_dir = pathlib.Path(temp_dir) / REFERENCE_REPOSITORY
        git_with_askpass(
            ["clone", repo_clone_url(INTERNAL_BASE_URL, REFERENCE_REPOSITORY), str(repo_dir)],
            username=admin_user,
            password=admin_password,
        )
        run(["git", "config", "user.name", "System Manager"], cwd=repo_dir)
        run(["git", "config", "user.email", f"{GIT_FORGE_ADMIN_USER}@forge.agentic.local"], cwd=repo_dir)

        if repo_is_managed_reference(repo_dir) or repo_is_seedable_default(repo_dir):
            sync_reference_template(repo_dir)
            run(["git", "add", "-A"], cwd=repo_dir)
            status = run(["git", "status", "--porcelain"], cwd=repo_dir)
            if status.stdout.strip():
                run(["git", "commit", "-m", "Bootstrap reference eight queens E2E repository"], cwd=repo_dir)
                git_with_askpass(["push", "origin", "main"], username=admin_user, password=admin_password, cwd=repo_dir)
                info(f"seeded managed reference repository '{REFERENCE_REPOSITORY}'")
        else:
            info(
                "reference repository already contains non-managed content; "
                "leaving main branch untouched"
            )

        git_with_askpass(["fetch", "origin"], username=admin_user, password=admin_password, cwd=repo_dir)
        for branch_name in REFERENCE_AGENT_BRANCHES:
            ensure_remote_branch_exists(repo_dir, branch_name, username=admin_user, password=admin_password)

    ensure_main_branch_protection(admin_user, admin_password)


def write_if_changed(path: pathlib.Path, content: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text(encoding="utf-8") == content:
        os.chmod(path, mode)
        return
    path.write_text(content, encoding="utf-8")
    os.chmod(path, mode)


def ensure_git_include(gitconfig_path: pathlib.Path, include_path: str) -> None:
    include_block = f"[include]\n\tpath = {include_path}\n"
    if gitconfig_path.exists():
        existing = gitconfig_path.read_text(encoding="utf-8")
        if include_path in existing:
            os.chmod(gitconfig_path, 0o660)
            return
        content = existing.rstrip() + "\n\n" + include_block
    else:
        content = include_block
    gitconfig_path.parent.mkdir(parents=True, exist_ok=True)
    gitconfig_path.write_text(content, encoding="utf-8")
    os.chmod(gitconfig_path, 0o660)


def ensure_gitconfig_value(gitconfig_path: pathlib.Path, key: str, value: str) -> None:
    gitconfig_path.parent.mkdir(parents=True, exist_ok=True)
    gitconfig_path.touch(exist_ok=True)
    run(["git", "config", "--file", str(gitconfig_path), key, value])
    os.chmod(gitconfig_path, 0o660)


def account_container_ssh_dir(account: dict[str, object]) -> str:
    return str(account.get("container_ssh_dir") or f"{account['container_home']}/.ssh")


def bootstrap_git_home(account: dict[str, object]) -> None:
    host_home = pathlib.Path(str(account["host_home"]))
    container_home = str(account["container_home"])
    container_ssh_dir = account_container_ssh_dir(account)
    username = str(account["username"])
    display_name = str(account["display_name"])
    config_dir = host_home / ".config" / "agentic"
    local_bin_dir = host_home / ".local" / "bin"
    helper_path = config_dir / "git-forge-credential.sh"
    include_path = config_dir / "git-forge.gitconfig"
    env_path = config_dir / "git-forge.env"
    gitconfig_path = host_home / ".gitconfig"
    container_ssh_key_path = f"{container_ssh_dir}/id_ed25519"
    container_known_hosts_path = f"{container_ssh_dir}/known_hosts"
    clone_url_internal = repo_clone_url(INTERNAL_BASE_URL, SHARED_REPOSITORY)
    clone_url_host = repo_clone_url(HOST_BASE_URL, SHARED_REPOSITORY)
    reference_clone_url_internal = repo_clone_url(INTERNAL_BASE_URL, REFERENCE_REPOSITORY)
    reference_clone_url_host = repo_clone_url(HOST_BASE_URL, REFERENCE_REPOSITORY)
    container_helper_path = f"{container_home}/.config/agentic/git-forge-credential.sh"
    container_include_path = f"{container_home}/.config/agentic/git-forge.gitconfig"

    local_bin_dir.mkdir(parents=True, exist_ok=True)
    config_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(local_bin_dir, 0o770)
    os.chmod(config_dir, 0o770)

    helper_content = f"""#!/bin/sh
set -eu
action="${{1:-get}}"
case "${{action}}" in
  get) ;;
  *) exit 0 ;;
esac

host=""
protocol=""
while IFS='=' read -r key value; do
  case "${{key}}" in
    host) host="${{value}}" ;;
    protocol) protocol="${{value}}" ;;
  esac
done

case "${{protocol}}:${{host}}" in
  http:optional-forgejo|http:optional-forgejo:*|http:127.0.0.1|http:127.0.0.1:*)
    ;;
  *)
    exit 0
    ;;
esac

printf 'username=%s\\n' {shlex.quote(username)}
printf 'password=%s\\n' "$(cat /run/secrets/git-forge.password)"
"""
    include_content = f"""# Managed by git_forge_bootstrap.py
[user]
\tname = {display_name}
\temail = {account["email"]}
[credential]
\thelper = {container_helper_path}
[init]
\tdefaultBranch = main
[core]
\tsshCommand = ssh -F /dev/null -i {container_ssh_key_path} -o UserKnownHostsFile={container_known_hosts_path} -o StrictHostKeyChecking=yes
"""
    env_content = (
        "# Managed by git_forge_bootstrap.py\n"
        f"export AGENTIC_GIT_FORGE_BASE_URL='{INTERNAL_BASE_URL}'\n"
        f"export AGENTIC_GIT_FORGE_SHARED_NAMESPACE='{GIT_FORGE_SHARED_NAMESPACE}'\n"
        f"export AGENTIC_GIT_FORGE_SHARED_REPOSITORY='{SHARED_REPOSITORY}'\n"
        f"export AGENTIC_GIT_FORGE_SHARED_CLONE_URL='{clone_url_internal}'\n"
        f"export AGENTIC_GIT_FORGE_HOST_CLONE_URL='{clone_url_host}'\n"
        f"export AGENTIC_GIT_FORGE_REFERENCE_REPOSITORY='{REFERENCE_REPOSITORY}'\n"
        f"export AGENTIC_GIT_FORGE_REFERENCE_CLONE_URL='{reference_clone_url_internal}'\n"
        f"export AGENTIC_GIT_FORGE_REFERENCE_HOST_CLONE_URL='{reference_clone_url_host}'\n"
        f"export AGENTIC_GIT_FORGE_REFERENCE_BRANCH='agent/{username}'\n"
        f"export AGENTIC_GIT_FORGE_SSH_URL='{repo_ssh_url(GIT_FORGE_INTERNAL_HOST, GIT_FORGE_INTERNAL_SSH_PORT, SHARED_REPOSITORY)}'\n"
        f"export AGENTIC_GIT_FORGE_SSH_REFERENCE_URL='{repo_ssh_url(GIT_FORGE_INTERNAL_HOST, GIT_FORGE_INTERNAL_SSH_PORT, REFERENCE_REPOSITORY)}'\n"
        f"export AGENTIC_GIT_FORGE_SSH_KEY_PATH='{container_ssh_key_path}'\n"
        f"export AGENTIC_GIT_FORGE_SSH_KNOWN_HOSTS='{container_known_hosts_path}'\n"
    )

    write_if_changed(helper_path, helper_content, 0o750)
    write_if_changed(include_path, include_content, 0o660)
    write_if_changed(env_path, env_content, 0o660)
    ensure_git_include(gitconfig_path, container_include_path)
    ensure_gitconfig_value(gitconfig_path, "user.name", display_name)
    ensure_gitconfig_value(gitconfig_path, "user.email", str(account["email"]))
    ensure_gitconfig_value(gitconfig_path, "credential.helper", container_helper_path)
    ensure_gitconfig_value(gitconfig_path, "init.defaultBranch", "main")


def forgejo_known_hosts_path() -> pathlib.Path:
    return pathlib.Path(AGENTIC_ROOT) / "secrets" / "ssh" / "forgejo_known_hosts"


def write_forgejo_known_hosts(container_id: str) -> None:
    scan = docker_exec(
        container_id,
        "/bin/bash",
        "--noprofile",
        "--norc",
        "-lc",
        f"ssh-keyscan -p {shlex.quote(GIT_FORGE_INTERNAL_SSH_PORT)} -T 5 {shlex.quote(GIT_FORGE_INTERNAL_HOST)} 2>/dev/null",
        check=False,
    )
    entries = [
        line.strip()
        for line in scan.stdout.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]

    if not entries:
        pub_keys = docker_exec(
            container_id,
            "/bin/bash",
            "--noprofile",
            "--norc",
            "-lc",
            "for f in /var/lib/gitea/ssh/*.pub /data/ssh/*.pub; do [ -f \"$f\" ] && cat \"$f\"; done",
            check=False,
        )
        for line in pub_keys.stdout.splitlines():
            parts = line.split()
            if len(parts) < 2 or not parts[0].startswith("ssh-"):
                continue
            entries.append(f"[{GIT_FORGE_INTERNAL_HOST}]:{GIT_FORGE_INTERNAL_SSH_PORT} {parts[0]} {parts[1]}")

    if not entries:
        fail("could not discover Forgejo SSH host key for known_hosts")

    path = forgejo_known_hosts_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o750)
    write_if_changed(path, "\n".join(entries) + "\n", 0o644)


def sync_agent_known_hosts(ssh_dir: pathlib.Path) -> None:
    source = forgejo_known_hosts_path()
    if not source.is_file():
        fail(f"Forgejo known_hosts source is missing: {source}")
    shutil.copy(str(source), str(ssh_dir / "known_hosts"))
    os.chmod(ssh_dir / "known_hosts", 0o644)


def chown_runtime(path: pathlib.Path) -> None:
    if os.geteuid() != 0:
        return
    os.chown(path, AGENT_RUNTIME_UID, AGENT_RUNTIME_GID)


def generate_ssh_key_pair(username: str) -> tuple[str, str]:
    """Generate or repair the stack-managed SSH key pair for an agent."""
    ssh_dir = pathlib.Path(AGENTIC_ROOT) / "secrets" / "ssh" / username
    ssh_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(ssh_dir, 0o700)

    private_key_path = ssh_dir / "id_ed25519"
    public_key_path = ssh_dir / "id_ed25519.pub"

    if not private_key_path.exists():
        run(["ssh-keygen", "-t", "ed25519", "-f", str(private_key_path), "-N", ""], check=True)
    if not public_key_path.exists():
        public_key = run(["ssh-keygen", "-y", "-f", str(private_key_path)]).stdout.strip()
        write_if_changed(public_key_path, public_key + "\n", 0o644)

    os.chmod(private_key_path, 0o600)
    os.chmod(public_key_path, 0o644)
    sync_agent_known_hosts(ssh_dir)
    chown_runtime(ssh_dir)
    chown_runtime(private_key_path)
    chown_runtime(public_key_path)
    chown_runtime(ssh_dir / "known_hosts")

    return private_key_path.read_text(encoding="utf-8").strip(), public_key_path.read_text(encoding="utf-8").strip()


def reconcile_ssh_permissions(account: dict[str, object]) -> None:
    ssh_reader_uids = tuple(account.get("ssh_reader_uids", ()))
    if not ssh_reader_uids:
        return
    if shutil.which("setfacl") is None:
        info(f"skip SSH ACL grants for user '{account['username']}': setfacl not available")
        return

    username = str(account["username"])
    ssh_dir = pathlib.Path(AGENTIC_ROOT) / "secrets" / "ssh" / username
    file_paths = [
        ssh_dir / "id_ed25519",
        ssh_dir / "id_ed25519.pub",
        ssh_dir / "known_hosts",
    ]

    if not ssh_dir.exists():
        return

    for uid in ssh_reader_uids:
        run(["setfacl", "-m", f"u:{uid}:--x", str(ssh_dir)], check=True)
        for path in file_paths:
            if path.exists():
                run(["setfacl", "-m", f"u:{uid}:r--", str(path)], check=True)


def add_ssh_key_to_forgejo(container_id: str, username: str, public_key: str, admin_user: str, admin_password: str) -> None:
    """Add SSH public key to Forgejo user."""
    # First check if the key already exists by trying to add it and handling the error gracefully
    result = api_request(
        container_id,
        "POST",
        f"/api/v1/admin/users/{urllib.parse.quote(username)}/keys",
        username=admin_user,
        password=admin_password,
        payload={
            "title": f"{username} SSH Key",
            "key": public_key,
        },
        expected=(201, 422),  # Accept 422 as a valid response (key already exists)
        allow_not_found=False,
    )
    
    if result is None:
        # Key was added successfully (201 status)
        info(f"added SSH key for user '{username}'")
    else:
        # Key already exists (422 status)
        info(f"SSH key already exists for user '{username}', skipping")


def write_bootstrap_state() -> None:
    BOOTSTRAP_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(BOOTSTRAP_DIR, 0o770)
    payload = {
        "host_url": HOST_BASE_URL,
        "internal_url": INTERNAL_BASE_URL,
        "compose_project": AGENTIC_COMPOSE_PROJECT,
        "admin_user": GIT_FORGE_ADMIN_USER,
        "shared_namespace": GIT_FORGE_SHARED_NAMESPACE,
        "shared_team": SHARED_TEAM,
        "shared_repository": SHARED_REPOSITORY,
        "shared_clone_url_host": repo_clone_url(HOST_BASE_URL, SHARED_REPOSITORY),
        "shared_clone_url_internal": repo_clone_url(INTERNAL_BASE_URL, SHARED_REPOSITORY),
        "reference_repository": REFERENCE_REPOSITORY,
        "reference_clone_url_host": repo_clone_url(HOST_BASE_URL, REFERENCE_REPOSITORY),
        "reference_clone_url_internal": repo_clone_url(INTERNAL_BASE_URL, REFERENCE_REPOSITORY),
        "reference_branch_policy": {
            "protected_branch": "main",
            "main_push_allowlist_users": [GIT_FORGE_ADMIN_USER],
            "agent_branches": list(REFERENCE_AGENT_BRANCHES),
        },
        "ssh_contract": {
            "host": GIT_FORGE_INTERNAL_HOST,
            "port": GIT_FORGE_INTERNAL_SSH_PORT,
            "known_hosts_filename": "known_hosts",
            "key_filename": "id_ed25519",
            "managed_paths": {
                str(account["username"]): account_container_ssh_dir(account)
                for account in MANAGED_ACCOUNTS
            },
        },
        "managed_users": [account["username"] for account in MANAGED_ACCOUNTS],
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    write_if_changed(BOOTSTRAP_DIR / "git-forge-bootstrap.json", json.dumps(payload, indent=2) + "\n", 0o660)


def main() -> None:
    global container_id
    container_id = service_container_id(SERVICE_NAME)
    if not container_id:
        fail(f"compose service '{SERVICE_NAME}' is not running in project '{AGENTIC_COMPOSE_PROJECT}'")

    wait_for_http(container_id)
    admin_password = read_secret(GIT_FORGE_ADMIN_USER)
    ensure_user(
        container_id,
        GIT_FORGE_ADMIN_USER,
        f"{GIT_FORGE_ADMIN_USER}@forge.agentic.local",
        admin_password,
        admin=True,
    )

    for account in MANAGED_ACCOUNTS:
        ensure_user(
            container_id,
            str(account["username"]),
            str(account["email"]),
            read_secret(str(account["username"])),
            admin=False,
        )

    clear_must_change_password(container_id)
    write_forgejo_known_hosts(container_id)
    ensure_org(GIT_FORGE_ADMIN_USER, admin_password)
    team_id = ensure_team(GIT_FORGE_ADMIN_USER, admin_password)
    for account in MANAGED_ACCOUNTS:
        ensure_team_member(team_id, str(account["username"]), GIT_FORGE_ADMIN_USER, admin_password)
        bootstrap_git_home(account)
        # Generate SSH key pair and add to Forgejo
        username = str(account["username"])
        private_key, public_key = generate_ssh_key_pair(username)
        reconcile_ssh_permissions(account)
        add_ssh_key_to_forgejo(container_id, username, public_key, GIT_FORGE_ADMIN_USER, admin_password)
    ensure_shared_repo(GIT_FORGE_ADMIN_USER, admin_password)
    seed_reference_repo(GIT_FORGE_ADMIN_USER, admin_password)
    write_bootstrap_state()
    info("git-forge bootstrap finished")


if __name__ == "__main__":
    main()
