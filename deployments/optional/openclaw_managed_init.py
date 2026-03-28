#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import shutil
from pathlib import Path

from openclaw_config_layers import extract_overlay
from openclaw_config_layers import get_path
from openclaw_config_layers import load_json
from openclaw_config_layers import set_path
from openclaw_config_layers import validate_overlay
from openclaw_config_layers import write_json


def backup_file(path: Path) -> str:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = path.with_name(f"{path.name}.repair-{timestamp}.bak")
    shutil.copy2(path, backup)
    return str(backup)


def load_template_overlay(path: Path) -> dict:
    payload = load_json(path, default={})
    return validate_overlay(payload, path)


def repair_overlay(overlay_file: Path, template_file: Path, workspace: str) -> dict:
    overlay_file.parent.mkdir(parents=True, exist_ok=True)
    template_overlay = load_template_overlay(template_file)
    backups: list[str] = []
    used_template = False
    parse_recovered = False
    current_payload = {}

    if overlay_file.exists():
        try:
            current_payload = load_json(overlay_file, default={})
        except SystemExit:
            backups.append(backup_file(overlay_file))
            current_payload = dict(template_overlay)
            used_template = True
            parse_recovered = True

    candidate = extract_overlay(current_payload) if isinstance(current_payload, dict) else {}
    current_workspace = get_path(candidate, ("agents", "defaults", "workspace"))

    try:
        normalized = validate_overlay(candidate, overlay_file)
    except SystemExit:
        if overlay_file.exists() and not parse_recovered:
            backups.append(backup_file(overlay_file))
        normalized = dict(template_overlay)
        used_template = True

    set_path(normalized, ("agents", "defaults", "workspace"), workspace)
    normalized = validate_overlay(normalized, overlay_file)
    write_json(overlay_file, normalized, mode=0o640)

    return {
        "backups": backups,
        "current_workspace": current_workspace or "",
        "repaired_workspace": workspace,
        "used_template": used_template,
        "workspace_changed": current_workspace != workspace,
    }


def repair_state_file(state_file: Path) -> dict:
    state_file.parent.mkdir(parents=True, exist_ok=True)
    backups: list[str] = []
    created = False
    reset = False

    if not state_file.exists():
        write_json(state_file, {}, mode=0o600)
        created = True
        return {"backups": backups, "created": created, "reset": reset}

    try:
        payload = load_json(state_file, default={})
        if not isinstance(payload, dict):
            raise SystemExit(f"{state_file}: expected a JSON object")
    except SystemExit:
        backups.append(backup_file(state_file))
        write_json(state_file, {}, mode=0o600)
        reset = True

    return {"backups": backups, "created": created, "reset": reset}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Repair stack-managed OpenClaw init inputs")
    parser.add_argument("--overlay-file", required=True, type=Path)
    parser.add_argument("--overlay-template-file", required=True, type=Path)
    parser.add_argument("--state-file", required=True, type=Path)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--workspace-host-dir", required=True, type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    args.workspace_host_dir.mkdir(parents=True, exist_ok=True)

    overlay = repair_overlay(args.overlay_file, args.overlay_template_file, args.workspace)
    state = repair_state_file(args.state_file)

    payload = {
        "overlay": overlay,
        "state": state,
        "workspace": {
            "host_dir": str(args.workspace_host_dir),
            "container_dir": args.workspace,
            "created": True,
        },
    }
    print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
