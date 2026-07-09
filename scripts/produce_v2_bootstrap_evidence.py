#!/usr/bin/env python3
"""Produce bounded local evidence for the first v2 walking-skeleton journey."""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
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
    except FileNotFoundError as exc:
        return {"status": "fail", "exit_code": None, "stdout": "", "stderr": str(exc)}
    except subprocess.TimeoutExpired as exc:
        return {
            "status": "fail",
            "exit_code": None,
            "stdout": exc.stdout or "",
            "stderr": f"timeout after {timeout_sec}s",
        }
    return {
        "status": "pass" if proc.returncode == 0 else "fail",
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-4000:],
        "stderr": proc.stderr[-4000:],
    }


def git_value(repo_root: Path, *args: str) -> str | None:
    result = run_cmd(["git", *args], repo_root, 10)
    if result["status"] != "pass":
        return None
    value = str(result["stdout"]).strip()
    return value or None


def tracked_files(repo_root: Path) -> list[str]:
    result = run_cmd(["git", "ls-files"], repo_root, 10)
    if result["status"] != "pass":
        return []
    return [line for line in str(result["stdout"]).splitlines() if line]


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def scan_static_security(repo_root: Path) -> dict[str, Any]:
    files = tracked_files(repo_root)
    docker_sock_hits: list[str] = []
    public_bind_hits: list[str] = []
    likely_secret_hits: list[str] = []
    scanned = 0
    text_suffixes = {
        ".env",
        ".json",
        ".md",
        ".py",
        ".sh",
        ".toml",
        ".txt",
        ".yaml",
        ".yml",
    }

    for rel in files:
        path = repo_root / rel
        if not path.is_file() or path.suffix not in text_suffixes:
            continue
        is_compose_policy_file = rel.startswith("compose/")
        is_runtime_config_file = (
            rel.startswith("compose/")
            or rel.startswith("evaluation/")
            or rel.startswith("deployments/")
        ) and path.suffix in {".env", ".json", ".toml", ".yaml", ".yml"}
        if not is_compose_policy_file and not is_runtime_config_file:
            continue
        scanned += 1
        text = read_text(path)
        if is_compose_policy_file and "docker.sock" in text:
            docker_sock_hits.append(rel)
        if is_compose_policy_file and ("0.0.0.0:" in text or "--bind 0.0.0.0" in text):
            public_bind_hits.append(rel)
        for marker in ("api_key=", "password=", "token=", "secret="):
            if is_runtime_config_file and marker in text.lower() and "example" not in rel.lower():
                likely_secret_hits.append(f"{rel}:{marker.rstrip('=')}")

    return {
        "files_scanned": scanned,
        "docker_sock_hits": sorted(set(docker_sock_hits)),
        "public_bind_hits": sorted(set(public_bind_hits)),
        "likely_secret_hits": sorted(set(likely_secret_hits)),
    }


def path_evidence(repo_root: Path) -> dict[str, Any]:
    required_paths = {
        "agent": repo_root / "agent",
        "doctor": repo_root / "scripts" / "doctor.sh",
        "snapshot": repo_root / "deployments" / "releases" / "snapshot.sh",
        "rollback": repo_root / "deployments" / "releases" / "rollback.sh",
        "release_validator": repo_root / "deployments" / "releases" / "validate_release_artifacts.py",
        "v2_spec_validator": repo_root / "scripts" / "validate_v2_evaluation_specs.py",
        "v2_evaluator": repo_root / "scripts" / "run_v2_evaluation.py",
    }
    return {
        name: {
            "path": str(path.relative_to(repo_root)),
            "exists": path.exists(),
            "executable": os.access(path, os.X_OK),
        }
        for name, path in required_paths.items()
    }


def all_paths_present(paths: dict[str, dict[str, Any]]) -> bool:
    return all(item["exists"] for item in paths.values())


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Produce v2 bootstrap-doctor evidence JSON.")
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--output", type=Path, help="Write evidence JSON to this file instead of stdout.")
    parser.add_argument("--run-doctor", action="store_true", help="Run ./agent doctor with a bounded timeout.")
    parser.add_argument("--doctor-timeout-sec", type=int, default=60)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    generated_at = now_utc()
    try:
        spec_validator.validate_all(repo_root)
        spec_status = "pass"
        spec_detail: dict[str, Any] = {"validator": "scripts/validate_v2_evaluation_specs.py"}
    except SystemExit as exc:
        spec_status = "fail"
        spec_detail = {"exit_code": exc.code}

    paths = path_evidence(repo_root)
    static_security = scan_static_security(repo_root)
    doctor_result: dict[str, Any] | None = None
    if args.run_doctor:
        doctor_result = run_cmd(["./agent", "doctor"], repo_root, args.doctor_timeout_sec)

    static_preflight_pass = (
        spec_status == "pass"
        and all_paths_present(paths)
        and not static_security["docker_sock_hits"]
        and not static_security["public_bind_hits"]
        and not static_security["likely_secret_hits"]
    )
    doctor_pass = bool(doctor_result and doctor_result["status"] == "pass")
    bootstrap_status = "pass" if static_preflight_pass and doctor_pass else "partial" if static_preflight_pass else "fail"

    evidence = {
        "schema_version": "v2-bootstrap-evidence.v0",
        "generated_at": generated_at,
        "producer": "scripts/produce_v2_bootstrap_evidence.py",
        "runtime": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "repo_root": str(repo_root),
            "git_commit": git_value(repo_root, "rev-parse", "HEAD"),
            "git_branch": git_value(repo_root, "rev-parse", "--abbrev-ref", "HEAD"),
            "doctor_executed": bool(args.run_doctor),
        },
        "gates": {
            "p0-no-secret-or-data-leak": {
                "status": "pass" if static_preflight_pass else "fail",
                "evidence": {
                    "type": "static_repo_scan",
                    "generated_at": generated_at,
                    "likely_secret_hits": static_security["likely_secret_hits"],
                    "files_scanned": static_security["files_scanned"],
                },
            },
            "p0-no-direct-backend-or-docker-sock": {
                "status": "partial" if not static_security["docker_sock_hits"] else "fail",
                "evidence": {
                    "type": "static_forbidden_pattern_scan",
                    "generated_at": generated_at,
                    "docker_sock_hits": static_security["docker_sock_hits"],
                    "public_bind_hits": static_security["public_bind_hits"],
                    "note": "Direct model backend reachability is not runtime-validated by this producer.",
                },
            },
            "p0-recovery-proven": {
                "status": "partial" if paths["snapshot"]["exists"] and paths["rollback"]["exists"] else "fail",
                "evidence": {
                    "type": "release_recovery_static_paths",
                    "generated_at": generated_at,
                    "paths": {
                        "snapshot": paths["snapshot"],
                        "rollback": paths["rollback"],
                        "release_validator": paths["release_validator"],
                    },
                    "note": "Actual restore and rollback execution is not performed by this producer.",
                },
            },
        },
        "journeys": {
            "bootstrap-doctor": {
                "status": bootstrap_status,
                "evidence": {
                    "type": "bootstrap_doctor_static_preflight",
                    "generated_at": generated_at,
                    "spec_validation": {"status": spec_status, "detail": spec_detail},
                    "required_paths": paths,
                    "static_security": static_security,
                    "doctor": doctor_result
                    if doctor_result is not None
                    else {
                        "status": "not_run",
                        "reason": "Run with --run-doctor on a deployed stack to promote bootstrap-doctor to pass.",
                    },
                },
            }
        },
    }

    if args.output:
        write_json(args.output, evidence)
    else:
        print(json.dumps(evidence, indent=2, sort_keys=True))

    return 0 if bootstrap_status in {"pass", "partial"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
