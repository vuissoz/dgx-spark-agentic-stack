#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

INTEGRITY_FILE = "artifact-integrity.json"


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description="Seal a release directory with artifact checksums.")
    parser.add_argument("--release-dir", required=True)
    args = parser.parse_args()

    release_dir = pathlib.Path(args.release_dir)
    if not release_dir.is_dir():
        raise SystemExit(f"release directory is missing: {release_dir}")

    files: dict[str, str] = {}
    for path in sorted(p for p in release_dir.rglob("*") if p.is_file() and p.name != INTEGRITY_FILE):
        rel_path = path.relative_to(release_dir).as_posix()
        files[rel_path] = sha256_file(path)

    payload = {
        "schema": "agentic.release.integrity.v1",
        "file_count": len(files),
        "files": files,
    }
    (release_dir / INTEGRITY_FILE).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
