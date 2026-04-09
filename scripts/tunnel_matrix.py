#!/usr/bin/env python3
"""Generate and validate SSH tunnel artifacts for DGX Spark stack surfaces."""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
MANIFEST_PATH = SCRIPT_DIR / "tunnel_manifest.json"


def infer_runtime_root() -> Path:
    profile = os.environ.get("AGENTIC_PROFILE", "strict-prod")
    if profile == "rootless-dev":
        return Path(os.environ.get("AGENTIC_ROOT", str(Path.home() / ".local/share/agentic")))
    return Path(os.environ.get("AGENTIC_ROOT", "/srv/agentic"))


def load_runtime_env_file() -> dict[str, str]:
    runtime_env_path = infer_runtime_root() / "deployments" / "runtime.env"
    env: dict[str, str] = {}
    try:
        is_file = runtime_env_path.is_file()
    except OSError:
        return env
    if not is_file:
        return env
    try:
        content = runtime_env_path.read_text(encoding="utf-8")
    except OSError:
        return env
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        env[key] = value
    return env


def load_effective_env() -> dict[str, str]:
    env = load_runtime_env_file()
    env.update(os.environ)
    return env


def load_manifest() -> list[dict[str, object]]:
    payload = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    surfaces = payload.get("surfaces")
    if not isinstance(surfaces, list):
        raise SystemExit(f"invalid tunnel manifest: {MANIFEST_PATH}")
    return surfaces


def resolve_port(surface: dict[str, object], env: dict[str, str]) -> int:
    env_var = str(surface["env_var"])
    default_port = int(surface["default_port"])
    raw = env.get(env_var, str(default_port)).strip()
    try:
        port = int(raw)
    except ValueError as exc:
        raise SystemExit(f"invalid integer for {env_var}: {raw!r}") from exc
    if port <= 0 or port > 65535:
        raise SystemExit(f"port out of range for {env_var}: {port}")
    return port


def is_port_open(port: int, timeout: float = 0.35) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except OSError:
        return False


def enrich_surfaces(manifest: list[dict[str, object]], env: dict[str, str]) -> list[dict[str, object]]:
    enriched: list[dict[str, object]] = []
    for surface in manifest:
        entry = dict(surface)
        port = resolve_port(entry, env)
        entry["resolved_port"] = port
        entry["status"] = "open" if is_port_open(port) else "closed"
        client_urls = entry.get("client_urls", [])
        entry["resolved_client_urls"] = [str(item).format(port=port) for item in client_urls]
        enriched.append(entry)
    return enriched


def surface_lookup(surfaces: list[dict[str, object]]) -> dict[str, dict[str, object]]:
    return {str(surface["id"]): surface for surface in surfaces}


def select_surfaces(
    surfaces: list[dict[str, object]],
    *,
    all_surfaces: bool,
    surface_ids: list[str],
    enabled_only: bool,
) -> list[dict[str, object]]:
    selected: list[dict[str, object]]
    if surface_ids:
        lookup = surface_lookup(surfaces)
        missing = [surface_id for surface_id in surface_ids if surface_id not in lookup]
        if missing:
            raise SystemExit(
                "unknown tunnel surface(s): "
                + ", ".join(sorted(missing))
                + ". Run 'agent tunnel list --all' to inspect valid ids."
            )
        selected = [lookup[surface_id] for surface_id in surface_ids]
    elif all_surfaces:
        selected = list(surfaces)
    else:
        selected = [surface for surface in surfaces if bool(surface.get("default"))]

    if enabled_only:
        selected = [surface for surface in selected if surface.get("status") == "open"]
    if not selected:
        raise SystemExit("no tunnel surfaces selected")
    return selected


def split_ssh_target(raw: str) -> tuple[str | None, str]:
    value = raw.strip()
    if not value:
        raise SystemExit("--ssh-target must be non-empty")
    if "@" in value:
        user, host = value.rsplit("@", 1)
        user = user.strip()
        host = host.strip()
        if not user or not host:
            raise SystemExit(f"invalid --ssh-target: {raw!r}")
        return user, host
    return None, value


def render_shell_script(selected: list[dict[str, object]], ssh_target: str, platform_name: str) -> str:
    escaped_default_target = ssh_target.replace("'", "'\"'\"'")
    forward_lines = []
    for surface in selected:
        port = int(surface["resolved_port"])
        forward_lines.append(f'  -L {port}:127.0.0.1:{port} \\')
    targets = []
    for surface in selected:
        label = str(surface["label"])
        for url in surface["resolved_client_urls"]:
            targets.append(f"#   - {label}: {url}")
    return "\n".join(
        [
            "#!/usr/bin/env bash",
            "set -euo pipefail",
            "",
            f"# Generated by scripts/tunnel_matrix.py for {platform_name}.",
            "# Open the forwarded URLs locally after the SSH session is established:",
            *targets,
            "",
            f"SSH_TARGET_DEFAULT='{escaped_default_target}'",
            'SSH_TARGET="${1:-${SSH_TARGET_DEFAULT}}"',
            '[[ -n "${SSH_TARGET}" ]] || { echo "usage: $0 [user@tailscale-host]" >&2; exit 1; }',
            "",
            "exec ssh -N -T \\",
            '  -o ExitOnForwardFailure=yes \\',
            '  -o ServerAliveInterval=30 \\',
            *forward_lines,
            '  "${SSH_TARGET}"',
            "",
        ]
    )


def render_powershell_script(selected: list[dict[str, object]], ssh_target: str) -> str:
    forward_tokens = []
    for surface in selected:
        port = int(surface["resolved_port"])
        forward_tokens.append(f'  "-L", "{port}:127.0.0.1:{port}"')
    targets = []
    for surface in selected:
        label = str(surface["label"])
        for url in surface["resolved_client_urls"]:
            targets.append(f"#   - {label}: {url}")
    lines = [
        'param([string]$SshTarget = "' + ssh_target.replace('"', '`"') + '")',
        '$ErrorActionPreference = "Stop"',
        "",
        "# Generated by scripts/tunnel_matrix.py for Windows PowerShell.",
        "# Open the forwarded URLs locally after the SSH session is established:",
        *targets,
        "",
        "$forwardArgs = @(",
        *forward_tokens,
        ")",
        '& ssh.exe "-N" "-T" "-o" "ExitOnForwardFailure=yes" "-o" "ServerAliveInterval=30" @forwardArgs $SshTarget',
        "exit $LASTEXITCODE",
        "",
    ]
    return "\n".join(lines)


def render_iphone_config(selected: list[dict[str, object]], ssh_target: str, name: str) -> str:
    user, host = split_ssh_target(ssh_target)
    lines = [
        "# OpenSSH config snippet for iPhone SSH clients that support local forwarding.",
        "# Compatible with OpenSSH-style clients such as Blink or manual Termius setup.",
        f"Host {name}",
        f"  HostName {host}",
    ]
    if user:
        lines.append(f"  User {user}")
    lines.extend(
        [
            "  RequestTTY no",
            "  ExitOnForwardFailure yes",
            "  ServerAliveInterval 30",
        ]
    )
    for surface in selected:
        port = int(surface["resolved_port"])
        lines.append(f"  LocalForward {port} 127.0.0.1:{port}")
    lines.extend(["", "# After connecting, open locally on the iPhone:"])
    for surface in selected:
        label = str(surface["label"])
        for url in surface["resolved_client_urls"]:
            lines.append(f"#   - {label}: {url}")
    lines.append("")
    return "\n".join(lines)


def write_output(path_arg: str | None, content: str, executable: bool) -> None:
    if not path_arg or path_arg == "-":
        sys.stdout.write(content)
        return
    output_path = Path(path_arg)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(content, encoding="utf-8")
    if executable:
        output_path.chmod(0o755)


def cmd_list(args: argparse.Namespace) -> int:
    env = load_effective_env()
    selected = select_surfaces(
        enrich_surfaces(load_manifest(), env),
        all_surfaces=args.all,
        surface_ids=args.surface,
        enabled_only=args.enabled,
    )
    if args.json:
        payload = []
        for surface in selected:
            payload.append(
                {
                    "id": surface["id"],
                    "label": surface["label"],
                    "stack": surface["stack"],
                    "default": surface["default"],
                    "env_var": surface["env_var"],
                    "port": surface["resolved_port"],
                    "status": surface["status"],
                    "client_urls": surface["resolved_client_urls"],
                    "description": surface["description"],
                }
            )
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0

    header = f"{'id':<18} {'port':>5} {'stack':<8} {'status':<7} label"
    print(header)
    print("-" * len(header))
    for surface in selected:
        print(
            f"{str(surface['id']):<18} "
            f"{int(surface['resolved_port']):>5} "
            f"{str(surface['stack']):<8} "
            f"{str(surface['status']):<7} "
            f"{surface['label']}"
        )
    return 0


def cmd_generate(args: argparse.Namespace) -> int:
    env = load_effective_env()
    selected = select_surfaces(
        enrich_surfaces(load_manifest(), env),
        all_surfaces=args.all,
        surface_ids=args.surface,
        enabled_only=args.enabled,
    )

    if args.platform in {"linux", "macos"}:
        content = render_shell_script(selected, args.ssh_target, args.platform)
        executable = True
    elif args.platform == "windows":
        content = render_powershell_script(selected, args.ssh_target)
        executable = False
    elif args.platform == "iphone":
        content = render_iphone_config(selected, args.ssh_target, args.name)
        executable = False
    else:
        raise SystemExit(f"unsupported platform: {args.platform}")

    write_output(args.output, content, executable=executable)
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    env = load_effective_env()
    selected = select_surfaces(
        enrich_surfaces(load_manifest(), env),
        all_surfaces=args.all,
        surface_ids=args.surface,
        enabled_only=False,
    )
    failures = []
    if args.json:
        payload = []
        for surface in selected:
            ok = surface["status"] == "open"
            payload.append(
                {
                    "id": surface["id"],
                    "port": surface["resolved_port"],
                    "status": "ok" if ok else "missing",
                    "client_urls": surface["resolved_client_urls"],
                }
            )
            if not ok:
                failures.append(str(surface["id"]))
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        for surface in selected:
            port = int(surface["resolved_port"])
            if surface["status"] == "open":
                print(f"OK: {surface['id']} is reachable on 127.0.0.1:{port}")
            else:
                print(
                    f"FAIL: {surface['id']} is not reachable on 127.0.0.1:{port} "
                    f"(check whether the matching stack module is running)",
                    file=sys.stderr,
                )
                failures.append(str(surface["id"]))
    return 1 if failures else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate and validate multi-host SSH tunnel artifacts for the DGX Spark stack."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    common_select = argparse.ArgumentParser(add_help=False)
    common_select.add_argument("--all", action="store_true", help="Select all known tunnel surfaces.")
    common_select.add_argument(
        "--surface",
        action="append",
        default=[],
        help="Select a specific surface id. Repeat for multiple surfaces.",
    )

    list_parser = subparsers.add_parser("list", parents=[common_select], help="List tunnel surfaces.")
    list_parser.add_argument(
        "--enabled",
        action="store_true",
        help="Show only surfaces that are currently reachable on the local host.",
    )
    list_parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    list_parser.set_defaults(func=cmd_list)

    generate_parser = subparsers.add_parser(
        "generate",
        parents=[common_select],
        help="Generate a platform-specific tunnel artifact.",
    )
    generate_parser.add_argument("platform", choices=["linux", "macos", "windows", "iphone"])
    generate_parser.add_argument(
        "--ssh-target",
        required=True,
        help="SSH target in the form user@tailscale-host or tailscale-host.",
    )
    generate_parser.add_argument(
        "--enabled",
        action="store_true",
        help="Generate tunnels only for surfaces currently reachable on the local host.",
    )
    generate_parser.add_argument(
        "--output",
        help="Write the generated artifact to a file instead of stdout.",
    )
    generate_parser.add_argument(
        "--name",
        default="dgx-spark-stack",
        help="Host alias for iPhone/OpenSSH config output.",
    )
    generate_parser.set_defaults(func=cmd_generate)

    check_parser = subparsers.add_parser(
        "check",
        parents=[common_select],
        help="Validate that selected tunnel surfaces are currently reachable on the local host.",
    )
    check_parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    check_parser.set_defaults(func=cmd_check)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
