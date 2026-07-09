#!/usr/bin/env python3
"""Aggregate v2 evidence producer outputs into one evaluator input file."""

from __future__ import annotations

import argparse
import json
import platform
import shlex
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


DEFAULT_PRODUCERS = (
    "scripts/produce_v2_bootstrap_evidence.py",
    "scripts/produce_v2_context_isolation_evidence.py",
    "scripts/produce_v2_model_backend_failure_evidence.py",
    "scripts/produce_v2_snapshot_restore_rollback_evidence.py",
    "scripts/produce_v2_single_source_of_truth_evidence.py",
)
BOOTSTRAP_PRODUCER = "scripts/produce_v2_bootstrap_evidence.py"
SINGLE_SOURCE_PRODUCER = "scripts/produce_v2_single_source_of_truth_evidence.py"

STATUS_RANK = {"missing": 0, "pass": 1, "partial": 2, "fail": 3}


def now_utc() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot load evidence file {path}: {exc}")
    if not isinstance(data, dict):
        fail(f"evidence file must contain a JSON object: {path}")
    return data


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


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
        "stdout": proc.stdout,
        "stderr": proc.stderr[-4000:],
        "exit_code": proc.returncode,
    }


def git_value(repo_root: Path, *args: str) -> str | None:
    result = run_cmd(["git", *args], repo_root, 10)
    if result["status"] != "pass":
        return None
    value = str(result["stdout"]).strip()
    return value or None


def evidence_summary(evidence: dict[str, Any]) -> dict[str, Any]:
    runtime = evidence.get("runtime") or {}
    return {
        "schema_version": evidence.get("schema_version"),
        "producer": evidence.get("producer"),
        "evidence_kind": runtime.get("evidence_kind") if isinstance(runtime, dict) else None,
        "agentic_root": runtime.get("agentic_root") if isinstance(runtime, dict) else None,
        "journeys": sorted((evidence.get("journeys") or {}).keys()),
        "gates": sorted((evidence.get("gates") or {}).keys()),
    }


def aggregate_status(left: str, right: str) -> str:
    return left if STATUS_RANK.get(left, 0) >= STATUS_RANK.get(right, 0) else right


def observation_authoritative(value: dict[str, Any]) -> bool:
    evidence = value.get("evidence")
    if isinstance(evidence, dict) and evidence.get("authoritative") is False:
        return False
    return True


def aggregate_gate_observations(observations: list[dict[str, Any]]) -> str:
    if any(observation.get("status") == "fail" for observation in observations):
        return "fail"
    authoritative = [observation for observation in observations if observation.get("authoritative") is not False]
    selected = authoritative or observations
    status = "missing"
    for observation in selected:
        status = aggregate_status(status, str(observation.get("status", "missing")))
    return status


def merge_gate(target: dict[str, Any], key: str, value: dict[str, Any], producer: str | None) -> None:
    observation = {
        "producer": producer,
        "status": value.get("status", "missing"),
        "authoritative": observation_authoritative(value),
        "evidence": value.get("evidence"),
    }
    if key not in target["gates"]:
        target["gates"][key] = {
            "status": aggregate_gate_observations([observation]),
            "evidence": {
                "type": "aggregated_gate_evidence",
                "policy": "Any failing observation fails the gate. Otherwise authoritative observations decide status; non-authoritative observations are retained for audit.",
                "observations": [observation],
            },
        }
        return
    existing = target["gates"][key]
    existing_evidence = existing.setdefault("evidence", {"type": "aggregated_gate_evidence", "observations": []})
    observations = existing_evidence.setdefault("observations", [])
    observations.append(observation)
    existing["status"] = aggregate_gate_observations(observations)


def merge_named_section(target: dict[str, Any], source: dict[str, Any], section: str, producer: str | None) -> list[str]:
    conflicts: list[str] = []
    values = source.get(section)
    if values is None:
        return conflicts
    if not isinstance(values, dict):
        conflicts.append(f"{producer or '<unknown>'}: {section} must be an object")
        return conflicts
    for key, value in values.items():
        if section == "gates" and isinstance(value, dict):
            merge_gate(target, key, value, producer)
            continue
        if key in target[section] and target[section][key] != value:
            conflicts.append(f"conflicting {section}.{key} from {producer or '<unknown>'}")
            continue
        target[section][key] = value
    return conflicts


def parse_producer_arg(value: str) -> tuple[str, list[str]]:
    try:
        parts = shlex.split(value)
    except ValueError as exc:
        fail(f"invalid producer command: {exc}")
    if not parts:
        fail("producer command cannot be empty")
    return parts[0], parts[1:]


def default_producer_specs(args: argparse.Namespace) -> list[str]:
    specs = list(DEFAULT_PRODUCERS)
    rendered: list[str] = []
    for producer in specs:
        command = [producer]
        if producer == BOOTSTRAP_PRODUCER and args.run_bootstrap_doctor:
            command.append("--run-doctor")
            if args.bootstrap_doctor_command:
                command.extend(["--doctor-command", args.bootstrap_doctor_command])
        if producer == SINGLE_SOURCE_PRODUCER and args.single_source_agentic_root:
            command.extend(["--agentic-root", args.single_source_agentic_root])
            if args.single_source_profile:
                command.extend(["--profile", args.single_source_profile])
            if args.single_source_compose_project:
                command.extend(["--compose-project", args.single_source_compose_project])
            if args.single_source_bootstrap_runtime_target:
                command.append("--bootstrap-runtime-target")
            if args.single_source_require_live_stack:
                command.append("--require-live-stack")
        rendered.append(" ".join(shlex.quote(part) for part in command))
    return rendered


def collect_from_producer(repo_root: Path, producer: str, extra_args: list[str], timeout_sec: int) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    producer_path = repo_root / producer
    if not producer_path.is_file():
        return None, {"producer": producer, "status": "fail", "reason": "producer script missing"}
    result = run_cmd([str(producer_path), *extra_args], repo_root, timeout_sec)
    metadata = {
        "producer": producer,
        "status": result["status"],
        "exit_code": result["exit_code"],
        "stderr": result["stderr"],
    }
    if result["status"] != "pass":
        return None, metadata
    try:
        data = json.loads(result["stdout"])
    except json.JSONDecodeError as exc:
        metadata["status"] = "fail"
        metadata["reason"] = f"invalid producer JSON: {exc}"
        return None, metadata
    if not isinstance(data, dict):
        metadata["status"] = "fail"
        metadata["reason"] = "producer output is not a JSON object"
        return None, metadata
    metadata |= evidence_summary(data)
    return data, metadata


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Aggregate v2 evidence into one evaluator input.")
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--output", type=Path, help="Write combined evidence JSON to this file instead of stdout.")
    parser.add_argument("--input", action="append", type=Path, default=[], help="Merge an existing evidence JSON file.")
    parser.add_argument(
        "--producer",
        action="append",
        default=[],
        help="Run an evidence producer command relative to repo root. Use quotes for extra args.",
    )
    parser.add_argument("--no-default-producers", action="store_true", help="Do not run built-in v2 evidence producers.")
    parser.add_argument("--producer-timeout-sec", type=int, default=60)
    parser.add_argument("--run-bootstrap-doctor", action="store_true", help="Run the bootstrap producer with --run-doctor.")
    parser.add_argument("--bootstrap-doctor-command", help="Doctor command passed to the default bootstrap producer.")
    parser.add_argument("--single-source-agentic-root", help="Runtime root passed to the default single-source-of-truth producer.")
    parser.add_argument("--single-source-profile", default="rootless-dev", choices=("rootless-dev", "strict-prod"))
    parser.add_argument("--single-source-compose-project", default="agentic-v2-proof")
    parser.add_argument(
        "--single-source-bootstrap-runtime-target",
        action="store_true",
        help="Bootstrap the selected single-source runtime target before inspection.",
    )
    parser.add_argument(
        "--single-source-require-live-stack",
        action="store_true",
        help="Require running containers for the selected single-source compose project.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    try:
        spec_validator.validate_all(repo_root)
    except SystemExit as exc:
        return int(exc.code) if isinstance(exc.code, int) else 1

    combined: dict[str, Any] = {
        "schema_version": "v2-combined-evidence.v0",
        "generated_at": now_utc(),
        "producer": "scripts/aggregate_v2_evidence.py",
        "runtime": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "repo_root": str(repo_root),
            "git_commit": git_value(repo_root, "rev-parse", "HEAD"),
            "git_branch": git_value(repo_root, "rev-parse", "--abbrev-ref", "HEAD"),
            "evidence_kind": "combined_static",
            "producers": [],
        },
        "gates": {},
        "journeys": {},
    }
    conflicts: list[str] = []

    producer_specs = [] if args.no_default_producers else default_producer_specs(args)
    producer_specs.extend(args.producer)
    for producer_spec in producer_specs:
        producer, extra_args = parse_producer_arg(producer_spec)
        evidence, metadata = collect_from_producer(repo_root, producer, extra_args, args.producer_timeout_sec)
        combined["runtime"]["producers"].append(metadata)
        if evidence is None:
            conflicts.append(f"producer failed: {producer}")
            continue
        conflicts.extend(merge_named_section(combined, evidence, "gates", evidence.get("producer")))
        conflicts.extend(merge_named_section(combined, evidence, "journeys", evidence.get("producer")))

    for input_path in args.input:
        evidence = load_json(input_path)
        combined["runtime"]["producers"].append({"input": str(input_path), "status": "pass", **evidence_summary(evidence)})
        conflicts.extend(merge_named_section(combined, evidence, "gates", evidence.get("producer") or str(input_path)))
        conflicts.extend(merge_named_section(combined, evidence, "journeys", evidence.get("producer") or str(input_path)))

    combined["aggregation"] = {
        "status": "pass" if not conflicts else "fail",
        "conflicts": conflicts,
        "gates_total": len(combined["gates"]),
        "journeys_total": len(combined["journeys"]),
    }

    if args.output:
        write_json(args.output, combined)
    else:
        print(json.dumps(combined, indent=2, sort_keys=True))

    return 0 if not conflicts else 1


if __name__ == "__main__":
    raise SystemExit(main())
