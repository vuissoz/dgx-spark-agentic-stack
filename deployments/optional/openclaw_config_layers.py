#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import sys
from typing import Any


ALLOWED_OVERLAY_PATHS = {
    ("agents", "defaults", "workspace"),
    ("tools", "profile"),
    ("commands", "native"),
    ("commands", "nativeSkills"),
    ("commands", "restart"),
    ("commands", "ownerDisplay"),
    ("session", "dmScope"),
}

IMMUTABLE_TOKEN_SENTINEL = "__OPENCLAW_GATEWAY_TOKEN__"
MANAGED_PLUGIN_ID = "openclaw-chat-status"


def load_json(path: pathlib.Path, *, default: Any | None = None) -> Any:
    if not path.exists():
        return {} if default is None else default
    try:
        with path.open("r", encoding="utf-8") as fh:
            payload = json.load(fh)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{path}: invalid JSON ({exc})") from exc
    if not isinstance(payload, dict):
        raise SystemExit(f"{path}: expected a JSON object")
    return payload


def _render_json(payload: dict[str, Any]) -> str:
    return json.dumps(payload, indent=2, sort_keys=False) + "\n"


def write_json(path: pathlib.Path, payload: dict[str, Any], *, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = _render_json(payload)
    if path.exists():
        try:
            current = path.read_text(encoding="utf-8")
        except OSError:
            current = None
        else:
            if current == rendered:
                try:
                    os.chmod(path, mode)
                except OSError:
                    pass
                return
    tmp_path = path.with_name(f"{path.name}.tmp")
    with tmp_path.open("w", encoding="utf-8") as fh:
        fh.write(rendered)
    os.chmod(tmp_path, mode)
    tmp_path.replace(path)


def deep_copy(payload: Any) -> Any:
    return json.loads(json.dumps(payload))


def deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    merged = deep_copy(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = deep_copy(value)
    return merged


def prune_empty(value: Any) -> Any:
    if isinstance(value, dict):
        pruned: dict[str, Any] = {}
        for key, child in value.items():
            normalized = prune_empty(child)
            if normalized in ({}, []):
                continue
            pruned[key] = normalized
        return pruned
    if isinstance(value, list):
        return [prune_empty(item) for item in value]
    return value


def get_path(payload: dict[str, Any], path: tuple[str, ...]) -> Any:
    current: Any = payload
    for part in path:
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return deep_copy(current)


def set_path(payload: dict[str, Any], path: tuple[str, ...], value: Any) -> None:
    current = payload
    for part in path[:-1]:
        child = current.get(part)
        if not isinstance(child, dict):
            child = {}
            current[part] = child
        current = child
    current[path[-1]] = deep_copy(value)


def delete_path(payload: dict[str, Any], path: tuple[str, ...]) -> None:
    current: Any = payload
    stack: list[tuple[dict[str, Any], str]] = []
    for part in path[:-1]:
        if not isinstance(current, dict) or part not in current:
            return
        stack.append((current, part))
        current = current[part]
    if isinstance(current, dict):
        current.pop(path[-1], None)
    for parent, key in reversed(stack):
        child = parent.get(key)
        if isinstance(child, dict) and not child:
            parent.pop(key, None)


def collect_leaf_paths(payload: Any, prefix: tuple[str, ...] = ()) -> set[tuple[str, ...]]:
    if not isinstance(payload, dict):
        return {prefix} if prefix else set()
    paths: set[tuple[str, ...]] = set()
    for key, value in payload.items():
        if key.startswith("_agentic"):
            continue
        child_prefix = prefix + (key,)
        if isinstance(value, dict):
            child_paths = collect_leaf_paths(value, child_prefix)
            if child_paths:
                paths.update(child_paths)
            else:
                paths.add(child_prefix)
        else:
            paths.add(child_prefix)
    return paths


def validate_overlay(overlay: dict[str, Any], origin: pathlib.Path) -> dict[str, Any]:
    unknown = collect_leaf_paths(overlay) - ALLOWED_OVERLAY_PATHS
    if unknown:
        rendered = ", ".join(".".join(parts) for parts in sorted(unknown))
        raise SystemExit(f"{origin}: unsupported overlay keys: {rendered}")

    workspace = get_path(overlay, ("agents", "defaults", "workspace"))
    if workspace is not None:
        if not isinstance(workspace, str) or not workspace.startswith("/workspace/"):
            raise SystemExit(f"{origin}: agents.defaults.workspace must stay under /workspace/")

    for path in (
        ("tools", "profile"),
        ("commands", "native"),
        ("commands", "nativeSkills"),
        ("commands", "ownerDisplay"),
        ("session", "dmScope"),
    ):
        value = get_path(overlay, path)
        if value is None:
            continue
        if not isinstance(value, str) or not value.strip():
            raise SystemExit(f"{origin}: {'.'.join(path)} must be a non-empty string")

    restart = get_path(overlay, ("commands", "restart"))
    if restart is not None and not isinstance(restart, bool):
        raise SystemExit(f"{origin}: commands.restart must be a boolean")

    normalized: dict[str, Any] = {}
    for path in sorted(ALLOWED_OVERLAY_PATHS):
        value = get_path(overlay, path)
        if value is not None:
            set_path(normalized, path, value)
    return prune_empty(normalized)


def resolve_immutable(payload: dict[str, Any], gateway_token: str) -> dict[str, Any]:
    normalized = deep_copy(payload)
    normalized.pop("_agentic", None)

    auth = normalized.setdefault("gateway", {}).setdefault("auth", {})
    if auth.get("token") == IMMUTABLE_TOKEN_SENTINEL:
        auth["token"] = gateway_token
    elif "token" not in auth:
        auth["token"] = gateway_token
    return prune_empty(normalized)


def resolve_bridge(payload: dict[str, Any]) -> dict[str, Any]:
    normalized = deep_copy(payload)
    normalized.pop("_agentic", None)
    return prune_empty(normalized)


def strip_paths(payload: dict[str, Any], paths: set[tuple[str, ...]]) -> dict[str, Any]:
    result = deep_copy(payload)
    for path in sorted(paths):
        delete_path(result, path)
    return prune_empty(result)


def reconcile_managed_plugin_state(
    state: dict[str, Any], plugin_dir: pathlib.Path | str
) -> dict[str, Any]:
    normalized = deep_copy(state) if isinstance(state, dict) else {}
    plugins = normalized.setdefault("plugins", {})
    if not isinstance(plugins, dict):
        plugins = {}
        normalized["plugins"] = plugins

    allow = plugins.setdefault("allow", [])
    if not isinstance(allow, list):
        allow = []
        plugins["allow"] = allow
    if MANAGED_PLUGIN_ID not in allow:
        allow.append(MANAGED_PLUGIN_ID)

    entries = plugins.setdefault("entries", {})
    if not isinstance(entries, dict):
        entries = {}
        plugins["entries"] = entries
    entry = entries.setdefault(MANAGED_PLUGIN_ID, {})
    if not isinstance(entry, dict):
        entry = {}
        entries[MANAGED_PLUGIN_ID] = entry
    entry["enabled"] = True

    installs = plugins.setdefault("installs", {})
    if not isinstance(installs, dict):
        installs = {}
        plugins["installs"] = installs
    install_record = installs.setdefault(MANAGED_PLUGIN_ID, {})
    if not isinstance(install_record, dict):
        install_record = {}
        installs[MANAGED_PLUGIN_ID] = install_record

    plugin_dir_str = str(plugin_dir)
    install_record["source"] = "path"
    install_record["sourcePath"] = plugin_dir_str
    install_record["installPath"] = plugin_dir_str
    return prune_empty(normalized)


def extract_overlay(payload: dict[str, Any]) -> dict[str, Any]:
    overlay: dict[str, Any] = {}
    for path in sorted(ALLOWED_OVERLAY_PATHS):
        value = get_path(payload, path)
        if value is not None:
            set_path(overlay, path, value)
    return prune_empty(overlay)


def materialize_effective(
    immutable_file: pathlib.Path,
    bridge_file: pathlib.Path,
    overlay_file: pathlib.Path,
    state_file: pathlib.Path,
    effective_file: pathlib.Path,
    gateway_token_file: pathlib.Path,
) -> None:
    gateway_token = gateway_token_file.read_text(encoding="utf-8").strip()
    if not gateway_token:
        raise SystemExit(f"{gateway_token_file}: gateway token file is empty")

    immutable = resolve_immutable(load_json(immutable_file), gateway_token)
    bridge = resolve_bridge(load_json(bridge_file, default={}))
    overlay = validate_overlay(load_json(overlay_file, default={}), overlay_file)
    state = load_json(state_file, default={})

    immutable_paths = collect_leaf_paths(immutable)
    bridge_paths = collect_leaf_paths(bridge)
    state = strip_paths(state, immutable_paths | bridge_paths | ALLOWED_OVERLAY_PATHS)
    effective = deep_merge(deep_merge(deep_merge(immutable, bridge), overlay), state)

    write_json(effective_file, effective, mode=0o600)
    if not state_file.exists():
        write_json(state_file, state, mode=0o600)


def capture_layers(
    immutable_file: pathlib.Path,
    bridge_file: pathlib.Path,
    overlay_file: pathlib.Path,
    state_file: pathlib.Path,
    effective_file: pathlib.Path,
    gateway_token_file: pathlib.Path,
) -> None:
    gateway_token = gateway_token_file.read_text(encoding="utf-8").strip()
    if not gateway_token:
        raise SystemExit(f"{gateway_token_file}: gateway token file is empty")

    immutable = resolve_immutable(load_json(immutable_file), gateway_token)
    bridge = resolve_bridge(load_json(bridge_file, default={}))
    effective = load_json(effective_file)

    overlay_candidate = extract_overlay(effective)
    overlay = validate_overlay(overlay_candidate, overlay_file)
    immutable_paths = collect_leaf_paths(immutable)
    bridge_paths = collect_leaf_paths(bridge)
    state = strip_paths(effective, immutable_paths | bridge_paths | ALLOWED_OVERLAY_PATHS)
    state = reconcile_managed_plugin_state(
        state,
        pathlib.Path("/state/cli/openclaw-home/.openclaw/extensions") / MANAGED_PLUGIN_ID,
    )

    write_json(overlay_file, overlay, mode=0o640)
    write_json(state_file, state, mode=0o600)


def validate_host_layout(
    immutable_file: pathlib.Path,
    bridge_file: pathlib.Path,
    overlay_file: pathlib.Path,
    state_file: pathlib.Path,
) -> None:
    immutable = load_json(immutable_file)
    auth_token = get_path(immutable, ("gateway", "auth", "token"))
    if auth_token != IMMUTABLE_TOKEN_SENTINEL:
        raise SystemExit(
            f"{immutable_file}: gateway.auth.token must be the managed sentinel {IMMUTABLE_TOKEN_SENTINEL}"
        )
    gateway_mode = get_path(immutable, ("gateway", "mode"))
    gateway_bind = get_path(immutable, ("gateway", "bind"))
    gateway_auth_mode = get_path(immutable, ("gateway", "auth", "mode"))
    if gateway_mode != "local":
        raise SystemExit(f"{immutable_file}: gateway.mode must stay 'local'")
    if gateway_bind != "loopback":
        raise SystemExit(f"{immutable_file}: gateway.bind must stay 'loopback'")
    if gateway_auth_mode != "token":
        raise SystemExit(f"{immutable_file}: gateway.auth.mode must stay 'token'")
    load_json(bridge_file, default={})
    validate_overlay(load_json(overlay_file, default={}), overlay_file)
    load_json(state_file, default={})


def check_runtime(
    immutable_file: pathlib.Path,
    bridge_file: pathlib.Path,
    overlay_file: pathlib.Path,
    state_file: pathlib.Path,
    effective_file: pathlib.Path,
    gateway_token_file: pathlib.Path,
) -> None:
    gateway_token = gateway_token_file.read_text(encoding="utf-8").strip()
    if not gateway_token:
        raise SystemExit(f"{gateway_token_file}: gateway token file is empty")

    immutable = resolve_immutable(load_json(immutable_file), gateway_token)
    bridge = resolve_bridge(load_json(bridge_file, default={}))
    overlay = validate_overlay(load_json(overlay_file, default={}), overlay_file)
    state = load_json(state_file, default={})
    effective = load_json(effective_file)

    immutable_paths = collect_leaf_paths(immutable)
    bridge_paths = collect_leaf_paths(bridge)
    forbidden_in_state = collect_leaf_paths(state) & (immutable_paths | bridge_paths | ALLOWED_OVERLAY_PATHS)
    if forbidden_in_state:
        rendered = ", ".join(".".join(parts) for parts in sorted(forbidden_in_state))
        raise SystemExit(f"{state_file}: state file must not persist immutable/bridge/overlay keys: {rendered}")

    expected = deep_merge(deep_merge(deep_merge(immutable, bridge), overlay), state)
    if expected != effective:
        raise SystemExit(f"{effective_file}: effective config drifted from immutable+bridge+overlay+state layers")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="OpenClaw layered config helper")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(command: argparse.ArgumentParser, *, with_effective: bool = True, with_token: bool = True) -> None:
        command.add_argument("--immutable-file", required=True, type=pathlib.Path)
        command.add_argument("--bridge-file", required=True, type=pathlib.Path)
        command.add_argument("--overlay-file", required=True, type=pathlib.Path)
        command.add_argument("--state-file", required=True, type=pathlib.Path)
        if with_effective:
            command.add_argument("--effective-file", required=True, type=pathlib.Path)
        if with_token:
            command.add_argument("--gateway-token-file", required=True, type=pathlib.Path)

    add_common(sub.add_parser("materialize"), with_effective=True, with_token=True)
    add_common(sub.add_parser("capture"), with_effective=True, with_token=True)
    add_common(sub.add_parser("check-runtime"), with_effective=True, with_token=True)
    add_common(sub.add_parser("validate-host-layout"), with_effective=False, with_token=False)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "materialize":
        materialize_effective(
            args.immutable_file,
            args.bridge_file,
            args.overlay_file,
            args.state_file,
            args.effective_file,
            args.gateway_token_file,
        )
        return 0
    if args.command == "capture":
        capture_layers(
            args.immutable_file,
            args.bridge_file,
            args.overlay_file,
            args.state_file,
            args.effective_file,
            args.gateway_token_file,
        )
        return 0
    if args.command == "validate-host-layout":
        validate_host_layout(args.immutable_file, args.bridge_file, args.overlay_file, args.state_file)
        return 0
    if args.command == "check-runtime":
        check_runtime(
            args.immutable_file,
            args.bridge_file,
            args.overlay_file,
            args.state_file,
            args.effective_file,
            args.gateway_token_file,
        )
        return 0

    parser.error(f"unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
