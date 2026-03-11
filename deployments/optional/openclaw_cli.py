#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any


def now_ts() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def state_dir() -> Path:
    return Path(os.environ.get("OPENCLAW_CLI_STATE_DIR", "/state/cli"))


def workspace_root() -> Path:
    return Path(os.environ.get("OPENCLAW_CLI_WORKSPACE_ROOT", "/workspace"))


def config_defaults() -> dict[str, Any]:
    return {
        "gateway_url": os.environ.get("OPENCLAW_GATEWAY_URL", "http://127.0.0.1:8111"),
        "token_file": os.environ.get("OPENCLAW_AUTH_TOKEN_FILE", "/run/secrets/openclaw.token"),
        "webhook_secret_file": os.environ.get("OPENCLAW_WEBHOOK_SECRET_FILE", "/run/secrets/openclaw.webhook_secret"),
        "profile_file": os.environ.get("OPENCLAW_PROFILE_FILE", "/config/integration-profile.current.json"),
        "sections": {},
    }


def load_json(path: Path, fallback: Any) -> Any:
    if not path.exists():
        return fallback
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return fallback
    return payload


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def ensure_files() -> tuple[Path, Path, Path]:
    root = state_dir()
    root.mkdir(parents=True, exist_ok=True)
    return root / "config.json", root / "agents.json", root / "onboard.json"


def parse_set_values(items: list[str]) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for item in items:
        if "=" not in item:
            raise ValueError(f"invalid --set value '{item}', expected key=value")
        key, value = item.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError(f"invalid --set value '{item}', key is empty")
        parsed[key] = value
    return parsed


def cmd_onboard(args: argparse.Namespace) -> int:
    config_path, _agents_path, onboard_path = ensure_files()
    payload = load_json(config_path, config_defaults())
    if not isinstance(payload, dict):
        payload = config_defaults()

    target_workspace = args.workspace.strip() if args.workspace else "default"
    workspace_path = Path(target_workspace)
    if not workspace_path.is_absolute():
        workspace_path = workspace_root() / target_workspace
    workspace_path.mkdir(parents=True, exist_ok=True)

    payload.setdefault("sections", {})
    payload["workspace_default"] = str(workspace_path)
    payload["last_onboarded_at"] = now_ts()
    save_json(config_path, payload)

    onboard_payload = {
        "mode": "stack-shim",
        "onboarded_at": now_ts(),
        "workspace": str(workspace_path),
        "gateway_url": payload.get("gateway_url"),
        "non_interactive": bool(args.non_interactive),
    }
    save_json(onboard_path, onboard_payload)

    print(f"openclaw onboard completed (workspace={workspace_path})")
    return 0


def cmd_configure(args: argparse.Namespace) -> int:
    config_path, _agents_path, _onboard_path = ensure_files()
    payload = load_json(config_path, config_defaults())
    if not isinstance(payload, dict):
        payload = config_defaults()

    section = (args.section or "default").strip() or "default"
    sections = payload.get("sections")
    if not isinstance(sections, dict):
        sections = {}
        payload["sections"] = sections

    section_payload = sections.get(section)
    if not isinstance(section_payload, dict):
        section_payload = {}

    try:
        updates = parse_set_values(args.set_values or [])
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    section_payload.update(updates)
    sections[section] = section_payload
    payload["last_configured_at"] = now_ts()
    payload["last_configured_section"] = section
    save_json(config_path, payload)

    output = {
        "section": section,
        "values": section_payload,
        "config_file": str(config_path),
    }
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0


def cmd_agents_add(args: argparse.Namespace) -> int:
    _config_path, agents_path, _onboard_path = ensure_files()
    agents_payload = load_json(agents_path, {"agents": []})
    if not isinstance(agents_payload, dict):
        agents_payload = {"agents": []}

    items = agents_payload.get("agents")
    if not isinstance(items, list):
        items = []

    name = args.name.strip()
    if not name:
        print("ERROR: agent name cannot be empty", file=sys.stderr)
        return 2

    existing = None
    for entry in items:
        if isinstance(entry, dict) and str(entry.get("name", "")).strip() == name:
            existing = entry
            break

    if existing is None:
        existing = {
            "name": name,
            "created_at": now_ts(),
        }
        items.append(existing)

    if args.channel:
        existing["channel"] = args.channel.strip()
    if args.role:
        existing["role"] = args.role.strip()
    existing["updated_at"] = now_ts()

    agents_payload["agents"] = items
    save_json(agents_path, agents_payload)
    print(f"openclaw agents add completed (name={name})")
    return 0


def cmd_agents_list(_args: argparse.Namespace) -> int:
    _config_path, agents_path, _onboard_path = ensure_files()
    agents_payload = load_json(agents_path, {"agents": []})
    if not isinstance(agents_payload, dict):
        agents_payload = {"agents": []}

    items = agents_payload.get("agents")
    if not isinstance(items, list):
        items = []

    print(json.dumps({"agents": items}, indent=2, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="openclaw", description="OpenClaw CLI shim for stack-local workflows")
    parser.add_argument("--version", action="store_true", help="print version")

    sub = parser.add_subparsers(dest="command")

    onboard = sub.add_parser("onboard", help="initialize OpenClaw CLI state")
    onboard.add_argument("--workspace", default="default", help="workspace name or absolute path")
    onboard.add_argument("--non-interactive", action="store_true", help="non-interactive mode")
    onboard.set_defaults(func=cmd_onboard)

    configure = sub.add_parser("configure", help="update OpenClaw CLI configuration")
    configure.add_argument("--section", default="default", help="configuration section")
    configure.add_argument("--set", dest="set_values", action="append", default=[], help="set key=value (repeatable)")
    configure.set_defaults(func=cmd_configure)

    agents = sub.add_parser("agents", help="manage OpenClaw agent definitions")
    agents_sub = agents.add_subparsers(dest="agents_command")

    agents_add = agents_sub.add_parser("add", help="add or update an agent entry")
    agents_add.add_argument("name", help="agent name")
    agents_add.add_argument("--channel", default="", help="optional channel identifier")
    agents_add.add_argument("--role", default="", help="optional role label")
    agents_add.set_defaults(func=cmd_agents_add)

    agents_list = agents_sub.add_parser("list", help="list configured agents")
    agents_list.set_defaults(func=cmd_agents_list)

    return parser


def main() -> int:
    parser = build_parser()
    args, unknown = parser.parse_known_args()

    if args.version:
        print("openclaw-stack-shim 0.2.0")
        return 0

    if unknown:
        print(f"WARN: ignoring unsupported arguments: {' '.join(unknown)}", file=sys.stderr)

    func = getattr(args, "func", None)
    if callable(func):
        return int(func(args))

    parser.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
