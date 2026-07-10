#!/usr/bin/env python3
"""Check drift between beginner configuration docs and the live repo contract."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


DOC_VAR_RE = re.compile(r"`([A-Z][A-Z0-9_]+)`")
RUNTIME_SCHEMA_RE = re.compile(r"^([A-Z][A-Z0-9_]+)\|", re.MULTILINE)
TOKEN_BOUNDARY_TEMPLATE = r"(?<![A-Z0-9_]){name}(?![A-Z0-9_])"
IGNORED_DOC_TOKENS = {"GB", "MB", "TB"}
REQUIRED_DOC_EXTRAS = {
    "AGENTIC_STACK_ALL_TARGETS",
    "AGENTIC_OPTIONAL_MODULES",
    "AGENTIC_DOCKER_USER_CHAIN",
    "AGENTIC_DOCKER_USER_SOURCE_NETWORKS",
    "AGENTIC_ALLOW_NON_ROOT_NET_ADMIN",
    "AGENTIC_SKIP_DOCKER_USER_APPLY",
    "AGENTIC_SKIP_DOCKER_USER_CHECK",
    "AGENTIC_SKIP_HOST_NET_BACKUP",
    "AGENTIC_DOCTOR_CRITICAL_PORTS",
}
SOURCE_GLOBS = (
    "scripts/**/*",
    "deployments/**/*",
    "compose/*",
    "examples/**/*",
)
SOURCE_SKIP_PREFIXES = ("docs/", "tests/", ".git/")


def fail(message: str) -> int:
    sys.stderr.write(f"FAIL: {message}\n")
    return 1


def parse_doc_vars(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    return {item for item in DOC_VAR_RE.findall(text) if item not in IGNORED_DOC_TOKENS}


def parse_runtime_schema_vars(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    return set(RUNTIME_SCHEMA_RE.findall(text))


def source_files(repo_root: Path) -> list[Path]:
    files: set[Path] = set()
    for pattern in SOURCE_GLOBS:
        for path in repo_root.glob(pattern):
            if not path.is_file():
                continue
            rel = path.relative_to(repo_root).as_posix()
            if rel.startswith(SOURCE_SKIP_PREFIXES):
                continue
            files.add(path)
    return sorted(files)


def find_source_hits(var_name: str, files: list[Path], repo_root: Path) -> list[str]:
    pattern = re.compile(TOKEN_BOUNDARY_TEMPLATE.format(name=re.escape(var_name)))
    hits: list[str] = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="ignore")
        if pattern.search(text):
            hits.append(path.relative_to(repo_root).as_posix())
    return hits


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check configuration docs drift.")
    parser.add_argument("--repo-root", type=Path, default=Path("."))
    parser.add_argument(
        "--runtime-script",
        type=Path,
        default=Path("scripts/lib/runtime.sh"),
        help="runtime.sh path relative to repo root",
    )
    parser.add_argument(
        "--doc-en",
        type=Path,
        default=Path("docs/runbooks/configuration-explained-beginners.en.md"),
        help="English beginner configuration runbook",
    )
    parser.add_argument(
        "--doc-fr",
        type=Path,
        default=Path("docs/runbooks/configuration-expliquee-debutants.md"),
        help="French beginner configuration runbook",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    runtime_script = (repo_root / args.runtime_script).resolve()
    doc_en = (repo_root / args.doc_en).resolve()
    doc_fr = (repo_root / args.doc_fr).resolve()

    for path in (runtime_script, doc_en, doc_fr):
        if not path.is_file():
            return fail(f"missing required file: {path}")

    runtime_schema_vars = parse_runtime_schema_vars(runtime_script)
    if not runtime_schema_vars:
        return fail(f"runtime schema is empty in {runtime_script}")

    doc_en_vars = parse_doc_vars(doc_en)
    doc_fr_vars = parse_doc_vars(doc_fr)
    if doc_en_vars != doc_fr_vars:
        en_only = sorted(doc_en_vars - doc_fr_vars)
        fr_only = sorted(doc_fr_vars - doc_en_vars)
        details = []
        if en_only:
            details.append(f"{doc_en.name}-only: {', '.join(en_only)}")
        if fr_only:
            details.append(f"{doc_fr.name}-only: {', '.join(fr_only)}")
        return fail("beginner configuration docs drifted: " + "; ".join(details))

    documented_vars = doc_en_vars
    missing_runtime_vars = sorted(runtime_schema_vars - documented_vars)
    if missing_runtime_vars:
        return fail(
            "runtime schema variables missing from beginner config docs: "
            + ", ".join(missing_runtime_vars)
        )

    missing_required_extras = sorted(REQUIRED_DOC_EXTRAS - documented_vars)
    if missing_required_extras:
        return fail(
            "critical shell-only configuration variables missing from beginner config docs: "
            + ", ".join(missing_required_extras)
        )

    files = source_files(repo_root)
    stale_vars: list[str] = []
    for var_name in sorted(documented_vars):
        hits = find_source_hits(var_name, files, repo_root)
        if not hits:
            stale_vars.append(var_name)
    if stale_vars:
        return fail(
            "documented configuration variables no longer resolve to live repo sources: "
            + ", ".join(stale_vars)
        )

    print(
        "OK: configuration docs drift check passed "
        f"({len(runtime_schema_vars)} runtime vars, {len(documented_vars)} documented vars, "
        f"{len(files)} source files scanned)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
