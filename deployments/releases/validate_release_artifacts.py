#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

INTEGRITY_FILE = "artifact-integrity.json"
REQUIRED_FILES = (
    "compose.effective.yml",
    "compose.files",
    "health_report.json",
    "images.json",
    "release.meta",
    "runtime.env",
)
TEXT_FILE_SUFFIXES = {
    ".env",
    ".json",
    ".log",
    ".meta",
    ".txt",
    ".yml",
    ".yaml",
}
PRIVATE_KEY_MARKERS = (
    "-----BEGIN OPENSSH PRIVATE KEY-----",
    "-----BEGIN RSA PRIVATE KEY-----",
    "-----BEGIN EC PRIVATE KEY-----",
    "-----BEGIN PRIVATE KEY-----",
)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_integrity_manifest(path: pathlib.Path) -> tuple[dict[str, str], list[str]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}, ["release integrity manifest is missing"]
    except (OSError, json.JSONDecodeError) as exc:
        return {}, [f"release integrity manifest is unreadable: {exc}"]

    if not isinstance(payload, dict):
        return {}, ["release integrity manifest has an invalid schema"]
    files = payload.get("files")
    if not isinstance(files, dict) or not files:
        return {}, ["release integrity manifest has no file checksums"]

    checksums: dict[str, str] = {}
    errors: list[str] = []
    for rel_path, digest in files.items():
        if not isinstance(rel_path, str) or not rel_path:
            errors.append("release integrity manifest contains an invalid file path entry")
            continue
        if rel_path == INTEGRITY_FILE or pathlib.PurePosixPath(rel_path).is_absolute() or ".." in pathlib.PurePosixPath(rel_path).parts:
            errors.append(f"release integrity manifest contains a forbidden path: {rel_path}")
            continue
        if not isinstance(digest, str) or len(digest) != 64:
            errors.append(f"release integrity manifest contains an invalid sha256 for {rel_path}")
            continue
        checksums[rel_path] = digest.lower()
    return checksums, errors


def validate_manifest_entries(release_dir: pathlib.Path, checksums: dict[str, str]) -> list[str]:
    errors: list[str] = []
    actual_files = sorted(
        str(path.relative_to(release_dir))
        for path in release_dir.rglob("*")
        if path.is_file() and path.name != INTEGRITY_FILE
    )

    missing_required = [name for name in REQUIRED_FILES if name not in actual_files]
    for rel_path in missing_required:
        errors.append(f"release artifact is missing required file: {rel_path}")

    manifest_files = sorted(checksums)
    if actual_files != manifest_files:
        missing_from_manifest = sorted(set(actual_files) - set(manifest_files))
        extra_in_manifest = sorted(set(manifest_files) - set(actual_files))
        for rel_path in missing_from_manifest:
            errors.append(f"release integrity manifest does not cover artifact: {rel_path}")
        for rel_path in extra_in_manifest:
            errors.append(f"release integrity manifest references a missing artifact: {rel_path}")

    for rel_path, expected in sorted(checksums.items()):
        artifact_path = release_dir / rel_path
        if not artifact_path.is_file():
            continue
        actual = sha256_file(artifact_path)
        if actual != expected:
            errors.append(f"release artifact checksum mismatch: {rel_path}")
    return errors


def iter_secret_values(secrets_dir: pathlib.Path) -> list[tuple[str, str]]:
    values: list[tuple[str, str]] = []
    if not secrets_dir.is_dir():
        return values
    for path in sorted(p for p in secrets_dir.rglob("*") if p.is_file()):
        try:
            raw = path.read_text(encoding="utf-8").strip()
        except (OSError, UnicodeDecodeError):
            continue
        if len(raw) < 8:
            continue
        values.append((str(path.relative_to(secrets_dir)), raw))
    return values


def should_scan_text(path: pathlib.Path) -> bool:
    return path.suffix.lower() in TEXT_FILE_SUFFIXES or path.name in REQUIRED_FILES or path.name.endswith(".env")


def validate_secret_hygiene(release_dir: pathlib.Path, secrets_dir: pathlib.Path) -> list[str]:
    errors: list[str] = []
    secret_values = iter_secret_values(secrets_dir)
    for path in sorted(p for p in release_dir.rglob("*") if p.is_file()):
        if path.name == INTEGRITY_FILE or not should_scan_text(path):
            continue
        try:
            raw = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for marker in PRIVATE_KEY_MARKERS:
            if marker in raw:
                errors.append(f"release artifact leaks private key material: {path.relative_to(release_dir)}")
                break
        for secret_name, secret_value in secret_values:
            if secret_value in raw:
                errors.append(
                    f"release artifact leaks secret content from {secret_name}: {path.relative_to(release_dir)}"
                )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate release artifact integrity and secret hygiene.")
    parser.add_argument("--release-dir", required=True)
    parser.add_argument("--secrets-dir", required=True)
    args = parser.parse_args()

    release_dir = pathlib.Path(args.release_dir)
    secrets_dir = pathlib.Path(args.secrets_dir)
    integrity_path = release_dir / INTEGRITY_FILE

    checksums, errors = load_integrity_manifest(integrity_path)
    if errors and errors == ["release integrity manifest is missing"]:
        print("release integrity manifest is missing; run 'agent update' to reseal the active release")
        return 2
    if errors:
        for message in errors:
            print(message)
        return 1

    errors.extend(validate_manifest_entries(release_dir, checksums))
    errors.extend(validate_secret_hygiene(release_dir, secrets_dir))

    if errors:
        for message in errors:
            print(message)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
