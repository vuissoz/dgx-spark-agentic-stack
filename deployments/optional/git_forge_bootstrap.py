#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import os
import pathlib
import shlex
import subprocess
import sys
import time
import urllib.parse


SERVICE_NAME = "optional-forgejo"
SHARED_TEAM = "agents"
SHARED_REPOSITORY = os.environ.get("GIT_FORGE_SHARED_REPOSITORY", "shared-workbench")
AGENTIC_ROOT = os.environ.get("AGENTIC_ROOT", "/srv/agentic")
AGENTIC_COMPOSE_PROJECT = os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic")
GIT_FORGE_HOST_PORT = os.environ.get("GIT_FORGE_HOST_PORT", "13010")
GIT_FORGE_ADMIN_USER = os.environ.get("GIT_FORGE_ADMIN_USER", "system-manager")
GIT_FORGE_SHARED_NAMESPACE = os.environ.get("GIT_FORGE_SHARED_NAMESPACE", "agentic")
HOST_BASE_URL = f"http://127.0.0.1:{GIT_FORGE_HOST_PORT}"
INTERNAL_BASE_URL = "http://optional-forgejo:3000"
SECRETS_ROOT = pathlib.Path(AGENTIC_ROOT) / "secrets" / "runtime" / "git-forge"
BOOTSTRAP_DIR = pathlib.Path(AGENTIC_ROOT) / "optional" / "git" / "bootstrap"

MANAGED_ACCOUNTS = (
    {
        "username": "openclaw",
        "display_name": "OpenClaw",
        "email": "openclaw@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "openclaw" / "state" / "cli" / "openclaw-home",
        "container_home": "/state/cli/openclaw-home",
    },
    {
        "username": "openhands",
        "display_name": "OpenHands",
        "email": "openhands@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "openhands" / "state" / "home",
        "container_home": "/.openhands/home",
    },
    {
        "username": "comfyui",
        "display_name": "ComfyUI",
        "email": "comfyui@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "comfyui" / "user",
        "container_home": "/comfyui/user",
    },
    {
        "username": "claude",
        "display_name": "Claude",
        "email": "claude@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "claude" / "state" / "home",
        "container_home": "/state/home",
    },
    {
        "username": "codex",
        "display_name": "Codex",
        "email": "codex@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "codex" / "state" / "home",
        "container_home": "/state/home",
    },
    {
        "username": "opencode",
        "display_name": "OpenCode",
        "email": "opencode@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "opencode" / "state" / "home",
        "container_home": "/state/home",
    },
    {
        "username": "vibestral",
        "display_name": "Vibestral",
        "email": "vibestral@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "vibestral" / "state" / "home",
        "container_home": "/state/home",
    },
    {
        "username": "pi-mono",
        "display_name": "Pi Mono",
        "email": "pi-mono@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "optional" / "pi-mono" / "state" / "home",
        "container_home": "/state/home",
    },
    {
        "username": "goose",
        "display_name": "Goose",
        "email": "goose@forge.agentic.local",
        "host_home": pathlib.Path(AGENTIC_ROOT) / "optional" / "goose" / "state" / "home",
        "container_home": "/state/home",
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


def run(cmd: list[str], *, input_text: str | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        input=input_text,
        text=True,
        capture_output=True,
        check=check,
    )


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def info(message: str) -> None:
    print(f"INFO: {message}")


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
    return proc.stdout.strip().splitlines()[0] if proc.stdout.strip() else ""


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
        docker_exec(container_id, "/bin/bash", "--noprofile", "--norc", "-lc", cmd, input_text=f"{password}\n")
        info(f"created forge account '{username}'")
        return

    if admin and users[username]["is_admin"] != "true":
      fail(f"existing forge account '{username}' is not admin; manual repair is required")

    cmd = (
        "read -r pass; "
        f"exec forgejo admin user change-password --username {shlex.quote(username)} --password \"$pass\""
    )
    docker_exec(container_id, "/bin/bash", "--noprofile", "--norc", "-lc", cmd, input_text=f"{password}\n")


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
            "permission": "admin",
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


def ensure_shared_repo(admin_user: str, admin_password: str) -> None:
    existing = api_request(
        container_id,
        "GET",
        f"/api/v1/repos/{urllib.parse.quote(GIT_FORGE_SHARED_NAMESPACE)}/{urllib.parse.quote(SHARED_REPOSITORY)}",
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
        f"/api/v1/orgs/{urllib.parse.quote(GIT_FORGE_SHARED_NAMESPACE)}/repos",
        username=admin_user,
        password=admin_password,
        payload={
            "name": SHARED_REPOSITORY,
            "description": "Shared repository for stack-managed collaboration checks",
            "private": True,
            "auto_init": True,
            "default_branch": "main",
            "readme": "Default",
        },
        expected=(201,),
    )
    info(f"created shared forge repository '{GIT_FORGE_SHARED_NAMESPACE}/{SHARED_REPOSITORY}'")


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


def bootstrap_git_home(account: dict[str, object]) -> None:
    host_home = pathlib.Path(str(account["host_home"]))
    container_home = str(account["container_home"])
    username = str(account["username"])
    display_name = str(account["display_name"])
    config_dir = host_home / ".config" / "agentic"
    local_bin_dir = host_home / ".local" / "bin"
    helper_path = config_dir / "git-forge-credential.sh"
    include_path = config_dir / "git-forge.gitconfig"
    env_path = config_dir / "git-forge.env"
    gitconfig_path = host_home / ".gitconfig"
    clone_url_internal = f"{INTERNAL_BASE_URL}/{GIT_FORGE_SHARED_NAMESPACE}/{SHARED_REPOSITORY}.git"
    clone_url_host = f"{HOST_BASE_URL}/{GIT_FORGE_SHARED_NAMESPACE}/{SHARED_REPOSITORY}.git"
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
  http:optional-forgejo|http:127.0.0.1)
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
"""
    env_content = (
        "# Managed by git_forge_bootstrap.py\n"
        f"export AGENTIC_GIT_FORGE_BASE_URL='{INTERNAL_BASE_URL}'\n"
        f"export AGENTIC_GIT_FORGE_SHARED_NAMESPACE='{GIT_FORGE_SHARED_NAMESPACE}'\n"
        f"export AGENTIC_GIT_FORGE_SHARED_REPOSITORY='{SHARED_REPOSITORY}'\n"
        f"export AGENTIC_GIT_FORGE_SHARED_CLONE_URL='{clone_url_internal}'\n"
        f"export AGENTIC_GIT_FORGE_HOST_CLONE_URL='{clone_url_host}'\n"
    )

    write_if_changed(helper_path, helper_content, 0o750)
    write_if_changed(include_path, include_content, 0o660)
    write_if_changed(env_path, env_content, 0o660)
    ensure_git_include(gitconfig_path, container_include_path)


def write_bootstrap_state() -> None:
    BOOTSTRAP_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(BOOTSTRAP_DIR, 0o770)
    payload = {
        "host_url": HOST_BASE_URL,
        "internal_url": INTERNAL_BASE_URL,
        "admin_user": GIT_FORGE_ADMIN_USER,
        "shared_namespace": GIT_FORGE_SHARED_NAMESPACE,
        "shared_team": SHARED_TEAM,
        "shared_repository": SHARED_REPOSITORY,
        "shared_clone_url_host": f"{HOST_BASE_URL}/{GIT_FORGE_SHARED_NAMESPACE}/{SHARED_REPOSITORY}.git",
        "shared_clone_url_internal": f"{INTERNAL_BASE_URL}/{GIT_FORGE_SHARED_NAMESPACE}/{SHARED_REPOSITORY}.git",
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

    ensure_org(GIT_FORGE_ADMIN_USER, admin_password)
    team_id = ensure_team(GIT_FORGE_ADMIN_USER, admin_password)
    for account in MANAGED_ACCOUNTS:
        ensure_team_member(team_id, str(account["username"]), GIT_FORGE_ADMIN_USER, admin_password)
        bootstrap_git_home(account)
    ensure_shared_repo(GIT_FORGE_ADMIN_USER, admin_password)
    write_bootstrap_state()
    info("git-forge bootstrap finished")


if __name__ == "__main__":
    main()
