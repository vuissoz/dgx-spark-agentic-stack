#!/usr/bin/env python3
"""Produce local evidence for the v2 context-isolation walking-skeleton journey."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[0]
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import validate_v2_evaluation_specs as spec_validator  # noqa: E402


def now_utc() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def run_cmd(args: list[str], cwd: Path, timeout_sec: int) -> dict[str, Any]:
    try:
        proc = subprocess.run(
            args,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_sec,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        return {"status": "fail", "stdout": "", "stderr": str(exc), "exit_code": None}
    return {
        "status": "pass" if proc.returncode == 0 else "fail",
        "stdout": proc.stdout[-4000:],
        "stderr": proc.stderr[-4000:],
        "exit_code": proc.returncode,
    }


def git_value(repo_root: Path, *args: str) -> str | None:
    result = run_cmd(["git", *args], repo_root, 10)
    if result["status"] != "pass":
        return None
    value = str(result["stdout"]).strip()
    return value or None


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
    except ValueError:
        return False
    return True


def policy_read(context_root: Path, target: Path, *, unsafe_allow_cross_context: bool = False) -> dict[str, Any]:
    allowed = unsafe_allow_cross_context or is_relative_to(target, context_root)
    if not allowed:
        return {
            "status": "refused",
            "path": str(target),
            "context_root": str(context_root),
            "reason": "target path is outside context root",
        }
    try:
        content = target.read_text(encoding="utf-8")
    except OSError as exc:
        return {
            "status": "error",
            "path": str(target),
            "context_root": str(context_root),
            "reason": str(exc),
        }
    return {
        "status": "read",
        "path": str(target),
        "context_root": str(context_root),
        "content_sha256_prefix": hashlib.sha256(content.encode("utf-8")).hexdigest()[:16],
    }


def build_fixture(root: Path) -> dict[str, Path]:
    personal = root / "personal"
    project = root / "projects" / "ARTANY"
    personal.mkdir(parents=True)
    project.mkdir(parents=True)
    (personal / "allowed.txt").write_text("personal context data\n", encoding="utf-8")
    (project / "allowed.txt").write_text("project context data\n", encoding="utf-8")
    (project / "private.txt").write_text("project private data must not leak\n", encoding="utf-8")
    return {
        "personal_root": personal,
        "project_root": project,
        "personal_allowed": personal / "allowed.txt",
        "project_allowed": project / "allowed.txt",
        "project_private": project / "private.txt",
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Produce v2 context-isolation evidence JSON.")
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--output", type=Path, help="Write evidence JSON to this file instead of stdout.")
    parser.add_argument("--keep-fixture", action="store_true", help="Keep the disposable fixture directory and report its path.")
    parser.add_argument(
        "--unsafe-allow-cross-context",
        action="store_true",
        help="Test hook: disable the path guard to prove leak detection fails closed.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    generated_at = now_utc()
    try:
        spec_validator.validate_all(repo_root)
        spec_status = "pass"
    except SystemExit as exc:
        spec_status = "fail"
        spec_error: int | str | None = exc.code
    else:
        spec_error = None

    fixture_root = Path(tempfile.mkdtemp(prefix="agentic-v2-context-"))
    fixture_paths = build_fixture(fixture_root)
    same_personal = policy_read(fixture_paths["personal_root"], fixture_paths["personal_allowed"])
    same_project = policy_read(fixture_paths["project_root"], fixture_paths["project_allowed"])
    cross_context = policy_read(
        fixture_paths["personal_root"],
        fixture_paths["project_private"],
        unsafe_allow_cross_context=args.unsafe_allow_cross_context,
    )

    positive_pass = same_personal["status"] == "read" and same_project["status"] == "read"
    negative_pass = cross_context["status"] == "refused"
    context_status = "pass" if spec_status == "pass" and positive_pass and negative_pass else "fail"

    fixture_report = {
        "kept": args.keep_fixture,
        "root": str(fixture_root) if args.keep_fixture else None,
        "roots": {
            "personal": str(fixture_paths["personal_root"]),
            "project": str(fixture_paths["project_root"]),
        },
    }
    if not args.keep_fixture:
        shutil.rmtree(fixture_root, ignore_errors=True)

    evidence = {
        "schema_version": "v2-context-isolation-evidence.v0",
        "generated_at": generated_at,
        "producer": "scripts/produce_v2_context_isolation_evidence.py",
        "runtime": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "repo_root": str(repo_root),
            "git_commit": git_value(repo_root, "rev-parse", "HEAD"),
            "git_branch": git_value(repo_root, "rev-parse", "--abbrev-ref", "HEAD"),
            "evidence_kind": "local_simulated_policy",
        },
        "gates": {
            "p0-no-secret-or-data-leak": {
                "status": "pass" if negative_pass else "fail",
                "evidence": {
                    "type": "local_context_policy_negative_check",
                    "generated_at": generated_at,
                    "cross_context_attempt": cross_context,
                    "unsafe_allow_cross_context": args.unsafe_allow_cross_context,
                },
            },
            "p0-single-source-of-truth": {
                "status": "partial" if spec_status == "pass" else "fail",
                "evidence": {
                    "type": "local_context_manifest",
                    "generated_at": generated_at,
                    "note": "This producer proves one active root per local fixture context; deployed v2 source-of-truth is not implemented yet.",
                    "fixture": fixture_report,
                },
            },
        },
        "journeys": {
            "context-isolation": {
                "status": context_status,
                "evidence": {
                    "type": "local_context_policy_simulation",
                    "generated_at": generated_at,
                    "spec_validation": {"status": spec_status, "error": spec_error},
                    "positive_same_context_checks": [same_personal, same_project],
                    "negative_cross_context_check": cross_context,
                    "fixture": fixture_report,
                    "note": "This is local simulated policy evidence, not deployed OpenShell/runtime evidence.",
                },
            }
        },
    }

    if args.output:
        write_json(args.output, evidence)
    else:
        print(json.dumps(evidence, indent=2, sort_keys=True))

    return 0 if context_status == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
