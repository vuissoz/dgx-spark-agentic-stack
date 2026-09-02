#!/usr/bin/env python3
"""Idempotent, inventory-driven runtime secret initialization and checks."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INVENTORY = REPO_ROOT / "config" / "secrets.inventory.json"


class SecretError(Exception):
    pass


def csv_values(raw: str) -> set[str]:
    return {value.strip().lower() for value in raw.split(",") if value.strip()}


def load_inventory(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("version") != 1 or not isinstance(data.get("secrets"), list):
        raise SecretError(f"unsupported or invalid secret inventory: {path}")
    seen: set[str] = set()
    for item in data["secrets"]:
        required = {"id", "module", "profiles", "path", "required", "validation", "prompt"}
        if not required.issubset(item):
            raise SecretError(f"incomplete secret inventory entry: {item.get('id', '<unknown>')}")
        if item["id"] in seen:
            raise SecretError(f"duplicate secret inventory id: {item['id']}")
        seen.add(item["id"])
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts or not relative.parts:
            raise SecretError(f"unsafe runtime secret path for {item['id']}")
    return data


def is_active(item: dict[str, Any], profiles: set[str], modules: set[str]) -> bool:
    return bool(profiles.intersection(map(str.lower, item["profiles"]))) or bool(
        modules.intersection(map(str.lower, item.get("activation_modules", [])))
    )


def validation_error(value: str, rule: dict[str, Any]) -> str | None:
    if "\n" in value or "\r" in value:
        return "must be a single line"
    kind = rule.get("type")
    if kind == "min_length":
        minimum = int(rule["value"])
        return None if len(value) >= minimum else f"must contain at least {minimum} characters"
    if kind == "password":
        minimum = int(rule["min_length"])
        if len(value) < minimum:
            return f"must contain at least {minimum} characters"
        if value.casefold() in {str(v).casefold() for v in rule.get("forbidden", [])}:
            return "uses a forbidden placeholder value"
        return None
    if kind == "prefix_or_empty":
        prefix = str(rule["prefix"])
        return None if not value or value.startswith(prefix) else f"must start with {prefix}"
    if kind == "regex":
        return None if re.fullmatch(str(rule["value"]), value) else "has an invalid format"
    return f"uses unsupported validation type {kind}"


def read_status(path: Path, rule: dict[str, Any]) -> tuple[str, str | None]:
    if not path.exists():
        return "missing", None
    if not path.is_file() or path.is_symlink():
        return "invalid", "path is not a regular non-symlink file"
    try:
        raw = path.read_bytes()
    except OSError as exc:
        return "invalid", f"file is not readable ({exc.strerror})"
    try:
        value = raw.decode("utf-8")
    except UnicodeDecodeError:
        return "invalid", "value is not valid UTF-8"
    value = value[:-1] if value.endswith("\n") else value
    error = validation_error(value, rule)
    return ("valid", None) if error is None else ("invalid", error)


def metadata_errors(path: Path, uid: int, gid: int, directory: bool) -> list[str]:
    expected_mode = 0o700 if directory else 0o600
    try:
        info = path.stat(follow_symlinks=False)
    except OSError as exc:
        return [f"cannot stat path ({exc.strerror})"]
    errors: list[str] = []
    if stat.S_IMODE(info.st_mode) != expected_mode:
        errors.append(f"mode must be {expected_mode:o}")
    if info.st_uid != uid or info.st_gid != gid:
        errors.append(f"owner must be uid={uid} gid={gid}")
    return errors


def repair_metadata(path: Path, uid: int, gid: int, directory: bool) -> None:
    expected_mode = 0o700 if directory else 0o600
    os.chmod(path, expected_mode, follow_symlinks=False)
    info = path.stat(follow_symlinks=False)
    if info.st_uid != uid or info.st_gid != gid:
        if os.geteuid() != 0:
            raise SecretError(f"cannot correct owner for {path}; rerun with the required privileges")
        os.chown(path, uid, gid, follow_symlinks=False)


def ensure_directories(runtime_root: Path, target: Path, uid: int, gid: int, fix: bool) -> list[str]:
    problems: list[str] = []
    current = runtime_root
    directories = [runtime_root.parent, runtime_root]
    for part in target.parent.relative_to(runtime_root).parts:
        current = current / part
        directories.append(current)
    for directory in directories:
        if not directory.exists():
            if not fix:
                problems.append(f"directory missing: {directory}")
                continue
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if not directory.is_dir() or directory.is_symlink():
            problems.append(f"secret directory is not a regular directory: {directory}")
            continue
        errors = metadata_errors(directory, uid, gid, True)
        if errors and fix:
            repair_metadata(directory, uid, gid, True)
            print(f"FIXED: secret directory metadata: {directory}")
            errors = metadata_errors(directory, uid, gid, True)
        problems.extend(f"{directory}: {error}" for error in errors)
    return problems


def atomic_write(path: Path, value: str, uid: int, gid: int) -> None:
    if os.geteuid() != 0 and (uid != os.getuid() or gid != os.getgid()):
        raise SecretError(
            f"cannot create {path} with owner uid={uid} gid={gid}; rerun with the required privileges"
        )
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(value)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        if os.geteuid() == 0:
            os.chown(temporary, uid, gid)
        os.replace(temporary, path)
        os.chmod(path, 0o600, follow_symlinks=False)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def prompt_new(item: dict[str, Any]) -> str:
    while True:
        first = getpass.getpass(f"{item['prompt']}: ")
        second = getpass.getpass(f"Confirm {item['prompt']}: ")
        if first != second:
            print(f"ERROR: confirmation mismatch for secret id={item['id']}", file=sys.stderr)
            continue
        error = validation_error(first, item["validation"])
        if error:
            print(f"ERROR: invalid value for secret id={item['id']}: {error}", file=sys.stderr)
            continue
        return first


def run(args: argparse.Namespace) -> int:
    inventory = load_inventory(args.inventory)
    runtime_root = Path(os.environ.get("AGENTIC_ROOT", "/srv/agentic")) / "secrets" / "runtime"
    uid = int(os.environ.get("AGENT_RUNTIME_UID", os.getuid()))
    gid = int(os.environ.get("AGENT_RUNTIME_GID", os.getgid()))
    strict_prod = os.environ.get("AGENTIC_PROFILE", "") == "strict-prod"
    directory_uid = 0 if strict_prod else os.getuid()
    directory_gid = 0 if strict_prod else os.getgid()
    profiles = {"core"} | csv_values(os.environ.get("COMPOSE_PROFILES", "")) | csv_values(args.profiles)
    modules = csv_values(os.environ.get("AGENTIC_OPTIONAL_MODULES", "")) | csv_values(args.modules)
    selected = [item for item in inventory["secrets"] if is_active(item, profiles, modules)]
    if args.rotate:
        matches = [item for item in inventory["secrets"] if item["id"] == args.rotate]
        if not matches:
            raise SecretError(f"unknown secret id for rotation: {args.rotate}")
        selected = matches

    interactive = not args.check
    if interactive and not sys.stdin.isatty():
        raise SecretError("interactive secret initialization requires a TTY; use --check for automation")

    failures = 0
    for item in selected:
        path = runtime_root / item["path"]
        directory_problems = ensure_directories(
            runtime_root, path, directory_uid, directory_gid, interactive
        )
        if directory_problems:
            for problem in directory_problems:
                hint = "; run './agent secrets'" if args.check else ""
                print(f"MISSING: secret id={item['id']}: {problem}{hint}", file=sys.stderr)
            failures += 1
            continue

        state, reason = read_status(path, item["validation"])
        if state == "valid" and not args.rotate:
            metadata = metadata_errors(path, uid, gid, False)
            if metadata and interactive:
                try:
                    repair_metadata(path, uid, gid, False)
                    print(f"FIXED: secret file metadata: id={item['id']} path={path}")
                    metadata = metadata_errors(path, uid, gid, False)
                except SecretError as exc:
                    metadata.append(str(exc))
            if metadata:
                for problem in metadata:
                    print(f"INVALID: secret id={item['id']}: {problem}", file=sys.stderr)
                failures += 1
            else:
                print(f"OK: secret id={item['id']} status=valid")
            continue

        if not item["required"] and state == "missing" and not args.rotate:
            print(f"OPTIONAL: secret id={item['id']} status=not-configured")
            continue
        if args.check:
            detail = reason or state
            print(
                f"{state.upper()}: required secret id={item['id']} path={path} ({detail}); run './agent secrets'",
                file=sys.stderr,
            )
            failures += 1
            continue

        if path.exists() and not args.rotate:
            answer = input(f"Secret id={item['id']} is invalid ({reason or state}). Replace it explicitly? [y/N] ")
            if answer.strip().lower() not in {"y", "yes"}:
                print(f"SKIPPED: invalid secret id={item['id']}; use './agent secrets rotate {item['id']}'")
                failures += 1
                continue
        value = prompt_new(item)
        atomic_write(path, value, uid, gid)
        verb = "ROTATED" if args.rotate else "CREATED"
        print(f"{verb}: secret id={item['id']} path={path}")

    required_count = sum(1 for item in selected if item["required"])
    optional_count = sum(1 for item in selected if not item["required"])
    print(
        f"SUMMARY: required={required_count} optional={optional_count} failures={failures} "
        f"profiles={','.join(sorted(profiles))} modules={','.join(sorted(modules)) or 'none'}"
    )
    return 1 if failures else 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="agent secrets",
        description="Initialize only missing/invalid active runtime secrets, or check them without disclosure.",
    )
    parser.add_argument("action", nargs="?", choices=["rotate"])
    parser.add_argument("secret_id", nargs="?")
    parser.add_argument("--check", action="store_true", help="non-interactive, read-only validation")
    parser.add_argument("--profiles", default="", help="additional active profile names (CSV; non-sensitive)")
    parser.add_argument("--modules", default="", help="additional optional module names (CSV; non-sensitive)")
    args = parser.parse_args(argv)
    args.inventory = DEFAULT_INVENTORY
    args.rotate = args.secret_id if args.action == "rotate" else None
    if args.action == "rotate" and not args.secret_id:
        parser.error("rotate requires a secret id")
    if args.action != "rotate" and args.secret_id:
        parser.error("unexpected positional argument")
    if args.rotate and args.check:
        parser.error("rotation cannot be combined with --check")
    return args


def main(argv: list[str] | None = None) -> int:
    try:
        return run(parse_args(sys.argv[1:] if argv is None else argv))
    except (SecretError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
