#!/usr/bin/env python3
"""Produce local evidence for v2 snapshot, restore, and rollback semantics."""

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


def file_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_digest(root: Path) -> dict[str, str]:
    digests: dict[str, str] = {}
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        digests[str(path.relative_to(root))] = file_digest(path)
    return digests


def copy_tree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def build_runtime_fixture(root: Path) -> dict[str, Path]:
    state = root / "state"
    releases = root / "deployments" / "releases"
    current = root / "deployments" / "current"
    state.mkdir(parents=True)
    releases.mkdir(parents=True)
    (state / "control.json").write_text(
        json.dumps({"version": 1, "projects": ["personal", "ARTANY"]}, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (state / "workspace.txt").write_text("checkpoint workspace data\n", encoding="utf-8")

    release_a = releases / "20260709T000000Z-a"
    release_b = releases / "20260709T000100Z-b"
    for release, image_digest in (
        (release_a, "sha256:" + "a" * 64),
        (release_b, "sha256:" + "b" * 64),
    ):
        release.mkdir()
        (release / "images.json").write_text(
            json.dumps({"ollama-gate": image_digest}, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        (release / "compose.effective.yml").write_text(f"name: {release.name}\n", encoding="utf-8")
    current.symlink_to(release_a)
    return {"state": state, "releases": releases, "current": current, "release_a": release_a, "release_b": release_b}


def read_current_release(current: Path) -> str:
    return current.resolve().name


def point_current(current: Path, target: Path) -> None:
    current.unlink(missing_ok=True)
    current.symlink_to(target)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Produce v2 snapshot-restore-rollback evidence JSON.")
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--output", type=Path, help="Write evidence JSON to this file instead of stdout.")
    parser.add_argument("--keep-fixture", action="store_true", help="Keep the disposable fixture directory and report its path.")
    parser.add_argument(
        "--unsafe-skip-restore",
        action="store_true",
        help="Test hook: leave mutated state in place to prove restore verification fails.",
    )
    parser.add_argument(
        "--unsafe-corrupt-rollback",
        action="store_true",
        help="Test hook: leave current pointed at the mutated release to prove rollback verification fails.",
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

    fixture_root = Path(tempfile.mkdtemp(prefix="agentic-v2-recovery-"))
    paths = build_runtime_fixture(fixture_root)
    checkpoint_state_digest = tree_digest(paths["state"])
    checkpoint_release = read_current_release(paths["current"])
    checkpoint_release_digest = tree_digest(paths["release_a"])

    snapshot_root = fixture_root / "snapshots" / "checkpoint"
    copy_tree(paths["state"], snapshot_root / "state")
    copy_tree(paths["release_a"], snapshot_root / "release")
    snapshot_manifest = {
        "state_digest": checkpoint_state_digest,
        "release": checkpoint_release,
        "release_digest": checkpoint_release_digest,
    }
    write_json(snapshot_root / "manifest.json", snapshot_manifest)

    (paths["state"] / "control.json").write_text(
        json.dumps({"version": 2, "projects": ["personal", "ARTANY", "MUTATED"]}, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (paths["state"] / "new-file.txt").write_text("mutated state\n", encoding="utf-8")
    point_current(paths["current"], paths["release_b"])

    mutated_state_digest = tree_digest(paths["state"])
    mutated_release = read_current_release(paths["current"])

    if not args.unsafe_skip_restore:
        copy_tree(snapshot_root / "state", paths["state"])
    if not args.unsafe_corrupt_rollback:
        point_current(paths["current"], paths["release_a"])

    restored_state_digest = tree_digest(paths["state"])
    restored_release = read_current_release(paths["current"])
    restored_release_digest = tree_digest(paths["current"].resolve())

    state_restored = restored_state_digest == checkpoint_state_digest
    rollback_exact = restored_release == checkpoint_release and restored_release_digest == checkpoint_release_digest
    recovery_status = "pass" if spec_status == "pass" and state_restored and rollback_exact else "fail"

    fixture_report = {
        "kept": args.keep_fixture,
        "root": str(fixture_root) if args.keep_fixture else None,
    }
    if not args.keep_fixture:
        shutil.rmtree(fixture_root, ignore_errors=True)

    evidence = {
        "schema_version": "v2-snapshot-restore-rollback-evidence.v0",
        "generated_at": generated_at,
        "producer": "scripts/produce_v2_snapshot_restore_rollback_evidence.py",
        "runtime": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "repo_root": str(repo_root),
            "git_commit": git_value(repo_root, "rev-parse", "HEAD"),
            "git_branch": git_value(repo_root, "rev-parse", "--abbrev-ref", "HEAD"),
            "evidence_kind": "local_simulated_recovery_policy",
        },
        "gates": {
            "p0-recovery-proven": {
                "status": "pass" if state_restored and rollback_exact else "fail",
                "evidence": {
                    "type": "local_snapshot_restore_rollback_check",
                    "generated_at": generated_at,
                    "state_restored": state_restored,
                    "rollback_exact": rollback_exact,
                    "unsafe_skip_restore": args.unsafe_skip_restore,
                    "unsafe_corrupt_rollback": args.unsafe_corrupt_rollback,
                },
            },
            "p0-single-source-of-truth": {
                "status": "partial" if spec_status == "pass" else "fail",
                "evidence": {
                    "type": "local_checkpoint_manifest",
                    "generated_at": generated_at,
                    "manifest": snapshot_manifest,
                    "note": "This producer uses one snapshot manifest as the local source of restore truth.",
                },
            },
        },
        "journeys": {
            "snapshot-restore-rollback": {
                "status": recovery_status,
                "evidence": {
                    "type": "local_snapshot_restore_rollback_simulation",
                    "generated_at": generated_at,
                    "spec_validation": {"status": spec_status, "error": spec_error},
                    "checkpoint": {
                        "state_digest": checkpoint_state_digest,
                        "release": checkpoint_release,
                        "release_digest": checkpoint_release_digest,
                    },
                    "mutation": {
                        "state_digest": mutated_state_digest,
                        "release": mutated_release,
                    },
                    "restored": {
                        "state_digest": restored_state_digest,
                        "release": restored_release,
                        "release_digest": restored_release_digest,
                        "state_restored": state_restored,
                        "rollback_exact": rollback_exact,
                    },
                    "fixture": fixture_report,
                    "note": "This is local simulated recovery-policy evidence, not deployed release rollback execution.",
                },
            }
        },
    }

    if args.output:
        write_json(args.output, evidence)
    else:
        print(json.dumps(evidence, indent=2, sort_keys=True))

    return 0 if recovery_status == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
