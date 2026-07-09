#!/usr/bin/env python3
"""Produce runtime-backed single-source-of-truth evidence for v2."""

from __future__ import annotations

import argparse
import json
import os
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


def run_cmd(
    args: list[str],
    cwd: Path,
    timeout_sec: int,
    *,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    try:
        proc = subprocess.run(
            args,
            cwd=cwd,
            env=env,
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


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def build_agent_env(agentic_root: Path) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "AGENTIC_PROFILE": "rootless-dev",
            "AGENTIC_ROOT": str(agentic_root),
            "AGENTIC_COMPOSE_PROJECT": "agentic-v2-proof",
        }
    )
    return env


def inspect_runtime_env(path: Path) -> dict[str, Any]:
    entries: dict[str, list[str]] = {}
    duplicates: dict[str, list[str]] = {}
    if not path.is_file():
        return {"exists": False, "entries": {}, "duplicates": {}, "status": "fail"}

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        entries.setdefault(key, []).append(value)
    for key, values in entries.items():
        if len(set(values)) > 1:
            duplicates[key] = values
    return {
        "exists": True,
        "entries": {key: values[-1] for key, values in entries.items()},
        "duplicates": duplicates,
        "status": "pass" if not duplicates else "fail",
    }


def inspect_backend_state(policy_path: Path, runtime_path: Path) -> dict[str, Any]:
    report: dict[str, Any] = {
        "policy_exists": policy_path.is_file(),
        "runtime_exists": runtime_path.is_file(),
        "status": "fail",
    }
    if not policy_path.is_file() or not runtime_path.is_file():
        return report

    try:
        policy = load_json(policy_path)
        runtime = load_json(runtime_path)
    except (OSError, json.JSONDecodeError) as exc:
        report["error"] = str(exc)
        return report

    policy_backend = str(policy.get("backend", ""))
    runtime_desired = str(runtime.get("desired_backend", ""))
    runtime_effective = str(runtime.get("effective_backend", ""))
    coherent = policy_backend == runtime_desired and runtime_effective in {"remote", policy_backend}
    report.update(
        {
            "policy_backend": policy_backend,
            "runtime_desired_backend": runtime_desired,
            "runtime_effective_backend": runtime_effective,
            "status": "pass" if coherent else "fail",
        }
    )
    return report


def ensure_release_fixture(
    repo_root: Path,
    agentic_root: Path,
    runtime_env_path: Path,
) -> tuple[Path, dict[str, Any]]:
    release_id = "20260709T000200Z-proof"
    release_dir = agentic_root / "deployments" / "releases" / release_id
    release_dir.mkdir(parents=True, exist_ok=True)
    (release_dir / "compose.effective.yml").write_text("name: proof\n", encoding="utf-8")
    (release_dir / "compose.files").write_text(f"{repo_root / 'compose' / 'compose.core.yml'}\n", encoding="utf-8")
    (release_dir / "health_report.json").write_text(
        json.dumps({"healthy": True, "services": [{"service": "ollama-gate", "state": "running", "health": "healthy"}]}, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
    (release_dir / "images.json").write_text(
        json.dumps(
            [
                {
                    "configured_image": "agentic/ollama-gate:local",
                    "container_id": "proof-container",
                    "health": "healthy",
                    "repo_digest": "agentic/ollama-gate@sha256:" + "1" * 64,
                    "resolved_image": "sha256:" + "1" * 64,
                    "service": "ollama-gate",
                    "state": "running",
                }
            ],
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    (release_dir / "release.meta").write_text(
        "\n".join(
            (
                f"release_id={release_id}",
                "reason=v2-single-source-of-truth-proof",
                f"created_at_utc={now_utc()}",
                "git_commit=proof",
                "docker_version=unknown",
                "docker_compose_version=unknown",
            )
        )
        + "\n",
        encoding="utf-8",
    )
    if runtime_env_path.is_file():
        shutil.copyfile(runtime_env_path, release_dir / "runtime.env")
    else:
        (release_dir / "runtime.env").write_text("", encoding="utf-8")

    seal = run_cmd(
        ["python3", str(repo_root / "deployments" / "releases" / "write_release_integrity.py"), "--release-dir", str(release_dir)],
        repo_root,
        30,
    )
    current_link = agentic_root / "deployments" / "current"
    current_link.parent.mkdir(parents=True, exist_ok=True)
    current_link.unlink(missing_ok=True)
    current_link.symlink_to(release_dir)
    validate = run_cmd(
        [
            "python3",
            str(repo_root / "deployments" / "releases" / "validate_release_artifacts.py"),
            "--release-dir",
            str(release_dir),
            "--secrets-dir",
            str(agentic_root / "secrets"),
        ],
        repo_root,
        30,
    )
    return release_dir, {"seal": seal, "validate": validate, "release_id": release_id}


def owner_candidates(root: Path, pattern: str) -> list[str]:
    return sorted(str(path.relative_to(root)) for path in root.glob(pattern))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Produce v2 single-source-of-truth evidence JSON.")
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--output", type=Path, help="Write evidence JSON to this file instead of stdout.")
    parser.add_argument("--keep-fixture", action="store_true", help="Keep the disposable fixture directory and report its path.")
    parser.add_argument(
        "--unsafe-duplicate-runtime-key",
        action="store_true",
        help="Test hook: append a contradictory duplicate runtime key to prove ambiguity fails closed.",
    )
    parser.add_argument(
        "--unsafe-shadow-owner-file",
        action="store_true",
        help="Test hook: create a shadow owner file to prove ambiguous ownership fails closed.",
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

    fixture_root = Path(tempfile.mkdtemp(prefix="agentic-v2-sot-"))
    agentic_root = fixture_root / "root"
    env = build_agent_env(agentic_root)
    backend_cmd = run_cmd(["./agent", "llm", "backend", "remote"], repo_root, 30, env=env)

    runtime_env_path = agentic_root / "deployments" / "runtime.env"
    policy_path = agentic_root / "gate" / "state" / "llm_backend.json"
    backend_runtime_path = agentic_root / "gate" / "state" / "llm_backend_runtime.json"

    if args.unsafe_duplicate_runtime_key and runtime_env_path.is_file():
        with runtime_env_path.open("a", encoding="utf-8") as fh:
            fh.write("AGENTIC_LLM_BACKEND=ollama\n")

    release_dir, release_report = ensure_release_fixture(repo_root, agentic_root, runtime_env_path)
    if args.unsafe_shadow_owner_file:
        shadow = agentic_root / "gate" / "state" / "llm_backend.shadow.json"
        shadow.write_text('{"backend":"ollama"}\n', encoding="utf-8")

    runtime_env = inspect_runtime_env(runtime_env_path)
    backend_state = inspect_backend_state(policy_path, backend_runtime_path)
    current_link = agentic_root / "deployments" / "current"
    current_target = str(current_link.resolve().relative_to(agentic_root)) if current_link.is_symlink() else None

    domains = {
        "runtime_env": {
            "owner_candidates": owner_candidates(agentic_root, "deployments/runtime*.env"),
            "expected_owner": "deployments/runtime.env",
            "duplicate_keys": runtime_env["duplicates"],
            "entries": runtime_env["entries"],
            "status": "pass"
            if runtime_env["status"] == "pass" and owner_candidates(agentic_root, "deployments/runtime*.env") == ["deployments/runtime.env"]
            else "fail",
        },
        "llm_backend_policy": {
            "owner_candidates": sorted(
                [
                    candidate
                    for candidate in owner_candidates(agentic_root, "gate/state/llm_backend*.json")
                    if candidate != "gate/state/llm_backend_runtime.json"
                ]
            ),
            "expected_owner": "gate/state/llm_backend.json",
            "backend_state": backend_state,
            "status": "pass"
            if backend_state["status"] == "pass"
            and sorted(
                [
                    candidate
                    for candidate in owner_candidates(agentic_root, "gate/state/llm_backend*.json")
                    if candidate != "gate/state/llm_backend_runtime.json"
                ]
            )
            == ["gate/state/llm_backend.json"]
            else "fail",
        },
        "llm_backend_runtime": {
            "owner_candidates": owner_candidates(agentic_root, "gate/state/llm_backend_runtime*.json"),
            "expected_owner": "gate/state/llm_backend_runtime.json",
            "status": "pass"
            if owner_candidates(agentic_root, "gate/state/llm_backend_runtime*.json") == ["gate/state/llm_backend_runtime.json"]
            else "fail",
        },
        "active_release": {
            "owner_candidates": owner_candidates(agentic_root, "deployments/current*"),
            "expected_owner": "deployments/current",
            "current_target": current_target,
            "release_dir": str(release_dir.relative_to(agentic_root)),
            "release_validation": release_report,
            "status": "pass"
            if owner_candidates(agentic_root, "deployments/current*") == ["deployments/current"]
            and current_target == str(release_dir.relative_to(agentic_root))
            and release_report["seal"]["status"] == "pass"
            and release_report["validate"]["status"] == "pass"
            else "fail",
        },
    }

    all_domains_pass = all(domain["status"] == "pass" for domain in domains.values())
    gate_status = "pass" if spec_status == "pass" and backend_cmd["status"] == "pass" and all_domains_pass else "fail"

    fixture_report = {"kept": args.keep_fixture, "root": str(fixture_root) if args.keep_fixture else None}
    if not args.keep_fixture:
        shutil.rmtree(fixture_root, ignore_errors=True)

    evidence = {
        "schema_version": "v2-single-source-of-truth-evidence.v0",
        "generated_at": generated_at,
        "producer": "scripts/produce_v2_single_source_of_truth_evidence.py",
        "runtime": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "repo_root": str(repo_root),
            "git_commit": git_value(repo_root, "rev-parse", "HEAD"),
            "git_branch": git_value(repo_root, "rev-parse", "--abbrev-ref", "HEAD"),
            "evidence_kind": "runtime_contract_owner_probe",
        },
        "gates": {
            "p0-single-source-of-truth": {
                "status": gate_status,
                "evidence": {
                    "type": "runtime_contract_owner_proof",
                    "generated_at": generated_at,
                    "authoritative": True,
                    "spec_validation": {"status": spec_status, "error": spec_error},
                    "agent_command": backend_cmd,
                    "domains": domains,
                    "unsafe_duplicate_runtime_key": args.unsafe_duplicate_runtime_key,
                    "unsafe_shadow_owner_file": args.unsafe_shadow_owner_file,
                    "fixture": fixture_report,
                    "note": "This proof is scoped to walking-skeleton runtime contracts owned by the agent CLI and active release artifacts.",
                },
            }
        },
    }

    if args.output:
        write_json(args.output, evidence)
    else:
        print(json.dumps(evidence, indent=2, sort_keys=True))

    return 0 if gate_status == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
