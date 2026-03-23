#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from typing import Any


def load_json(path: str) -> dict[str, Any]:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise SystemExit(f"{path}: manifest must be a JSON object")
    return payload


def require_string(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"manifest field must be a non-empty string: {key}")
    return value.strip()


def require_string_list(payload: dict[str, Any], key: str) -> list[str]:
    value = payload.get(key)
    if not isinstance(value, list) or not value or not all(isinstance(item, str) and item.strip() for item in value):
        raise SystemExit(f"manifest field must be a non-empty string array: {key}")
    return [item.strip() for item in value]


def validate_manifest(payload: dict[str, Any]) -> None:
    require_string(payload, "module")
    require_string(payload, "manifest_id")
    version = payload.get("manifest_version")
    if not isinstance(version, int) or version < 1:
      raise SystemExit("manifest_version must be an integer >= 1")

    auth = payload.get("auth")
    if not isinstance(auth, dict):
        raise SystemExit("auth must be an object")
    for key in ("api", "webhook", "gateway", "internal_lifecycle"):
        require_string(auth, key)

    compatibility = payload.get("compatibility")
    if not isinstance(compatibility, dict):
        raise SystemExit("compatibility must be an object")
    require_string_list(compatibility, "profiles")
    cli = compatibility.get("cli")
    if not isinstance(cli, dict):
        raise SystemExit("compatibility.cli must be an object")
    require_string(cli, "version_probe")
    require_string_list(cli, "supported_version_selectors")
    require_non_empty_version = cli.get("require_non_empty_version")
    if not isinstance(require_non_empty_version, bool):
        raise SystemExit("compatibility.cli.require_non_empty_version must be a boolean")

    files = payload.get("files")
    if not isinstance(files, dict):
        raise SystemExit("files must be an object")
    for key in ("required", "secrets", "state_roots"):
        require_string_list(files, key)

    network = payload.get("network")
    if not isinstance(network, dict):
        raise SystemExit("network must be an object")
    require_string_list(network, "allowed_base_urls")
    internal_endpoints = network.get("internal_endpoints")
    if not isinstance(internal_endpoints, dict):
        raise SystemExit("network.internal_endpoints must be an object")
    for key in ("api", "sandbox", "sandbox_lifecycle", "relay"):
        require_string(internal_endpoints, key)
    host_ports = network.get("host_loopback_ports")
    if not isinstance(host_ports, dict):
        raise SystemExit("network.host_loopback_ports must be an object")
    for key in ("webhook", "gateway", "relay"):
        value = host_ports.get(key)
        if not isinstance(value, int) or value <= 0:
            raise SystemExit(f"network.host_loopback_ports.{key} must be a positive integer")

    lifecycle = payload.get("lifecycle")
    if not isinstance(lifecycle, dict):
        raise SystemExit("lifecycle must be an object")
    for key in ("resolve", "verify", "plan", "apply", "status"):
        require_string_list(lifecycle, key)

    release = payload.get("release")
    if not isinstance(release, dict):
        raise SystemExit("release must be an object")
    require_string(release, "component")
    require_string(release, "global_release_relation")


def command_validate(args: argparse.Namespace) -> int:
    payload = load_json(args.manifest_file)
    validate_manifest(payload)
    return 0


def command_summary(args: argparse.Namespace) -> int:
    payload = load_json(args.manifest_file)
    validate_manifest(payload)
    summary = {
        "auth": payload["auth"],
        "component": payload["release"]["component"],
        "manifest_id": payload["manifest_id"],
        "module": payload["module"],
        "profiles": payload["compatibility"]["profiles"],
        "sandbox_lifecycle": payload["network"]["internal_endpoints"]["sandbox_lifecycle"],
    }
    print(json.dumps(summary, separators=(",", ":"), sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Validate/render the OpenClaw module manifest")
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--manifest-file", required=True)
    validate_parser.set_defaults(func=command_validate)

    summary_parser = subparsers.add_parser("summary")
    summary_parser.add_argument("--manifest-file", required=True)
    summary_parser.set_defaults(func=command_summary)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
