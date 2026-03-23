#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def load_json_file(path: str, default: Any) -> Any:
    file_path = Path(path)
    if not file_path.exists():
        return default
    return json.loads(file_path.read_text(encoding="utf-8"))


def write_json_file(path: str, payload: dict[str, Any]) -> None:
    file_path = Path(path)
    file_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = file_path.with_name(f"{file_path.name}.tmp")
    tmp_path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    tmp_path.replace(file_path)


def load_registry(path: str) -> dict[str, Any]:
    payload = load_json_file(path, {})
    if not isinstance(payload, dict):
        raise SystemExit(f"invalid operator registry: {path}")
    payload.setdefault("sandboxes", {})
    payload.setdefault("sessions", {})
    payload.setdefault("recent_expired", [])
    return payload


def load_runtime(path: str) -> dict[str, Any]:
    payload = load_json_file(path, {})
    if not isinstance(payload, dict):
        raise SystemExit(f"invalid operator runtime file: {path}")
    if not isinstance(payload.get("default_model"), str) or not payload.get("default_model", "").strip():
        raise SystemExit(f"operator runtime file must contain a non-empty default_model: {path}")
    return payload


def load_manifest_summary(path: str) -> dict[str, Any]:
    payload = load_json_file(path, {})
    if not isinstance(payload, dict):
        raise SystemExit(f"invalid module manifest: {path}")
    return {
        "manifest_id": payload.get("manifest_id"),
        "manifest_version": payload.get("manifest_version"),
        "sandbox_lifecycle": ((payload.get("network") or {}).get("internal_endpoints") or {}).get("sandbox_lifecycle"),
    }


def load_allowlist(path: str) -> list[str]:
    file_path = Path(path)
    if not file_path.exists():
        return []
    entries: list[str] = []
    seen: set[str] = set()
    for line in file_path.read_text(encoding="utf-8").splitlines():
        item = line.strip()
        if not item or item.startswith("#") or item in seen:
            continue
        seen.add(item)
        entries.append(item)
    return entries


def append_unique_line(path: str, value: str) -> bool:
    file_path = Path(path)
    file_path.parent.mkdir(parents=True, exist_ok=True)
    existing = load_allowlist(path)
    if value in existing:
        return False
    with file_path.open("a", encoding="utf-8") as handle:
        if file_path.stat().st_size > 0:
            handle.write("\n")
        handle.write(value)
    return True


def docker_exec_json(container: str, method: str, path: str, token_file: str, body: dict[str, Any] | None) -> dict[str, Any]:
    method = method.upper()
    lines = [
        "import json",
        "import pathlib",
        "import sys",
        "import urllib.error",
        "import urllib.request",
        f"token = pathlib.Path({token_file!r}).read_text(encoding='utf-8').strip()",
        "headers = {'Authorization': f'Bearer {token}'}",
        f"url = 'http://127.0.0.1:8112{path}'",
    ]
    if body is not None:
        encoded = json.dumps(body, separators=(",", ":"), sort_keys=True)
        lines.extend(
            [
                f"data = {encoded!r}.encode('utf-8')",
                "headers['Content-Type'] = 'application/json'",
            ]
        )
    else:
        lines.append("data = None")
    lines.extend(
        [
            f"req = urllib.request.Request(url, data=data, headers=headers, method={method!r})",
            "try:",
            "    with urllib.request.urlopen(req, timeout=5) as resp:",
            "        payload = json.loads(resp.read().decode('utf-8'))",
            "        payload['_http_status'] = resp.status",
            "        print(json.dumps(payload, separators=(',', ':'), sort_keys=True))",
            "except urllib.error.HTTPError as exc:",
            "    payload = json.loads(exc.read().decode('utf-8') or '{}')",
            "    payload['_http_status'] = exc.code",
            "    print(json.dumps(payload, separators=(',', ':'), sort_keys=True))",
            "    raise SystemExit(0)",
        ]
    )
    command = "\n".join(lines)
    result = subprocess.run(
        ["docker", "exec", container, "python3", "-c", command],
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(result.stderr.strip() or result.stdout.strip() or "docker exec failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON from sandbox internal API: {result.stdout}") from exc


def command_status(args: argparse.Namespace) -> int:
    registry = load_registry(args.operator_registry_file)
    runtime = load_runtime(args.operator_runtime_file)
    manifest = load_manifest_summary(args.manifest_file)
    payload = {
        "current_session_id": registry.get("current_session_id", ""),
        "default_model": runtime.get("default_model", ""),
        "manifest": manifest,
        "provider": registry.get("provider", ""),
        "sandboxes": len((registry.get("sandboxes") or {})),
        "sessions": len(
            [
                item
                for item in (registry.get("sessions") or {}).values()
                if isinstance(item, dict) and bool(item.get("active"))
            ]
        ),
        "updated_at": registry.get("updated_at", ""),
    }
    if args.json:
        print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
        return 0

    print(f"manifest={manifest.get('manifest_id', '-')}")
    print(f"default_model={payload['default_model']}")
    print(f"provider={payload['provider'] or '-'}")
    print(f"sandboxes={payload['sandboxes']}")
    print(f"sessions={payload['sessions']}")
    print(f"current_session_id={payload['current_session_id'] or '-'}")
    return 0


def command_policy_list(args: argparse.Namespace) -> int:
    payload = {
        "dm_targets": load_allowlist(args.dm_allowlist_file),
        "tools": load_allowlist(args.tool_allowlist_file),
    }
    if args.json:
        print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
        return 0

    print("dm_targets:")
    for item in payload["dm_targets"]:
        print(item)
    print("tools:")
    for item in payload["tools"]:
        print(item)
    return 0


def command_policy_add(args: argparse.Namespace) -> int:
    kind = args.kind.lower()
    value = args.value.strip()
    if not value:
        raise SystemExit("policy value must be non-empty")
    if kind in {"dm", "dm-target", "dm_target"}:
        target = args.dm_allowlist_file
        normalized_kind = "dm_target"
    elif kind == "tool":
        target = args.tool_allowlist_file
        normalized_kind = "tool"
    else:
        raise SystemExit("policy kind must be one of: dm-target, tool")

    changed = append_unique_line(target, value)
    payload = {"changed": changed, "kind": normalized_kind, "target_file": target, "value": value}
    if args.json:
        print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
        return 0
    print(f"{normalized_kind} {value} {'added' if changed else 'already-present'}")
    return 0


def command_model_set(args: argparse.Namespace) -> int:
    payload = load_runtime(args.operator_runtime_file)
    payload["default_model"] = args.model_id
    payload["updated_at"] = args.updated_at
    payload["updated_by"] = args.updated_by
    write_json_file(args.operator_runtime_file, payload)
    response = {"default_model": args.model_id, "operator_runtime_file": args.operator_runtime_file}
    if args.json:
        print(json.dumps(response, separators=(",", ":"), sort_keys=True))
        return 0
    print(f"default_model={args.model_id}")
    return 0


def command_sandbox_ls(args: argparse.Namespace) -> int:
    registry = load_registry(args.operator_registry_file)
    sandboxes = registry.get("sandboxes") or {}
    items = [sandboxes[key] for key in sorted(sandboxes.keys()) if isinstance(sandboxes.get(key), dict)]
    if args.json:
        print(json.dumps({"sandboxes": items}, separators=(",", ":"), sort_keys=True))
        return 0
    for item in items:
        print(
            "\t".join(
                [
                    str(item.get("sandbox_id", "")),
                    str(item.get("session_id", "")),
                    str(item.get("model", "")),
                    str(item.get("workspace", "")),
                ]
            )
        )
    return 0


def command_sandbox_destroy(args: argparse.Namespace) -> int:
    payload = docker_exec_json(
        args.sandbox_container,
        "DELETE",
        f"/v1/internal/sandboxes/{args.sandbox_id}",
        args.token_file,
        None,
    )
    if args.json:
        print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
        return 0
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="OpenClaw operator helper")
    parser.add_argument("--operator-registry-file", required=True)
    parser.add_argument("--operator-runtime-file", required=True)
    parser.add_argument("--manifest-file", required=True)
    parser.add_argument("--dm-allowlist-file", required=True)
    parser.add_argument("--tool-allowlist-file", required=True)

    subparsers = parser.add_subparsers(dest="command", required=True)

    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--json", action="store_true")
    status_parser.set_defaults(func=command_status)

    policy_parser = subparsers.add_parser("policy")
    policy_subparsers = policy_parser.add_subparsers(dest="policy_command", required=True)
    policy_list_parser = policy_subparsers.add_parser("list")
    policy_list_parser.add_argument("--json", action="store_true")
    policy_list_parser.set_defaults(func=command_policy_list)
    policy_add_parser = policy_subparsers.add_parser("add")
    policy_add_parser.add_argument("kind")
    policy_add_parser.add_argument("value")
    policy_add_parser.add_argument("--json", action="store_true")
    policy_add_parser.set_defaults(func=command_policy_add)

    model_parser = subparsers.add_parser("model")
    model_subparsers = model_parser.add_subparsers(dest="model_command", required=True)
    model_set_parser = model_subparsers.add_parser("set")
    model_set_parser.add_argument("model_id")
    model_set_parser.add_argument("--json", action="store_true")
    model_set_parser.add_argument("--updated-at", required=True)
    model_set_parser.add_argument("--updated-by", required=True)
    model_set_parser.set_defaults(func=command_model_set)

    sandbox_parser = subparsers.add_parser("sandbox")
    sandbox_subparsers = sandbox_parser.add_subparsers(dest="sandbox_command", required=True)
    sandbox_ls_parser = sandbox_subparsers.add_parser("ls")
    sandbox_ls_parser.add_argument("--json", action="store_true")
    sandbox_ls_parser.set_defaults(func=command_sandbox_ls)
    sandbox_destroy_parser = sandbox_subparsers.add_parser("destroy")
    sandbox_destroy_parser.add_argument("sandbox_id")
    sandbox_destroy_parser.add_argument("--json", action="store_true")
    sandbox_destroy_parser.add_argument("--sandbox-container", required=True)
    sandbox_destroy_parser.add_argument("--token-file", required=True)
    sandbox_destroy_parser.set_defaults(func=command_sandbox_destroy)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
