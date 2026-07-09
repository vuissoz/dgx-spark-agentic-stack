#!/usr/bin/env python3
"""Run the initial local-only v2 evaluation workflow.

This runner is intentionally static for the first v2 slice: it validates the
versioned specs, consumes a machine evidence file when available, and writes the
artifact bundle defined by PLAN.md section 15.4.9.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import socket
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


REDACTED = "[REDACTED]"
SECRET_KEY_PATTERN = re.compile(r"(token|secret|password|api[_-]?key|credential|private[_-]?key)", re.IGNORECASE)
EVALUATION_ID_PATTERN = re.compile(r"^[A-Za-z0-9_.:-]+$")

REQUIRED_ARTIFACTS = (
    "evaluation.json",
    "manifest.json",
    "gates.json",
    "runtime.json",
    "engineering.json",
    "pareto.json",
    "recovery.json",
    "report.md",
)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def now_utc() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def load_json(path: Path, *, required: bool = True) -> dict[str, Any]:
    if not path.is_file():
        if required:
            fail(f"missing JSON file: {path}")
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{path} is not valid JSON: {exc}")
    if not isinstance(data, dict):
        fail(f"{path} must contain a JSON object")
    return data


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_git(repo_root: Path, *args: str) -> str | None:
    try:
        proc = subprocess.run(
            ["git", *args],
            cwd=repo_root,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None
    value = proc.stdout.strip()
    return value or None


def short_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


def redact(value: Any, key: str = "") -> Any:
    if SECRET_KEY_PATTERN.search(key) and not key.startswith("p0-"):
        return REDACTED
    if isinstance(value, dict):
        return {str(k): redact(v, str(k)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(item, key) for item in value]
    if isinstance(value, str) and SECRET_KEY_PATTERN.search(value):
        return REDACTED
    return value


def default_artifact_root() -> Path:
    configured = os.environ.get("AGENTIC_V2_EVALUATION_ARTIFACT_ROOT")
    if configured:
        return Path(configured)
    agentic_root = os.environ.get("AGENTIC_ROOT")
    if agentic_root:
        return Path(agentic_root) / "artifacts" / "evaluations"
    return Path.home() / ".local" / "share" / "agentic" / "artifacts" / "evaluations"


def validate_evidence(evidence: dict[str, Any], specs: dict[str, dict[str, Any]]) -> tuple[list[dict[str, Any]], list[str]]:
    reasons: list[str] = []
    gate_evidence = evidence.get("gates")
    journey_evidence = evidence.get("journeys")
    if not isinstance(gate_evidence, dict):
        gate_evidence = {}
        reasons.append("evidence.gates is missing or not an object")
    if not isinstance(journey_evidence, dict):
        journey_evidence = {}
        reasons.append("evidence.journeys is missing or not an object")

    gates: list[dict[str, Any]] = []
    for gate in specs["promotion"]["mandatory_gates"]:
        gate_id = gate["gate_id"]
        raw = gate_evidence.get(gate_id)
        passed = isinstance(raw, dict) and raw.get("status") == "pass" and bool(raw.get("evidence"))
        if not passed:
            reasons.append(f"P0 gate evidence missing or not passing: {gate_id}")
        gates.append(
            {
                "gate_id": gate_id,
                "class": gate["class"],
                "description": gate["description"],
                "status": "pass" if passed else "missing",
                "evidence": redact(raw.get("evidence")) if isinstance(raw, dict) else None,
            }
        )

    for journey in specs["visible_corpus"]["journeys"]:
        journey_id = journey["journey_id"]
        raw = journey_evidence.get(journey_id)
        passed = isinstance(raw, dict) and raw.get("status") == "pass" and bool(raw.get("evidence"))
        if journey["class"] == "P0" and not passed:
            reasons.append(f"P0 journey evidence missing or not passing: {journey_id}")

    return gates, reasons


def build_journey_results(specs: dict[str, dict[str, Any]], evidence: dict[str, Any]) -> list[dict[str, Any]]:
    journey_evidence = evidence.get("journeys")
    if not isinstance(journey_evidence, dict):
        journey_evidence = {}
    results: list[dict[str, Any]] = []
    for journey in specs["visible_corpus"]["journeys"]:
        raw = journey_evidence.get(journey["journey_id"])
        passed = isinstance(raw, dict) and raw.get("status") == "pass" and bool(raw.get("evidence"))
        results.append(
            {
                "journey_id": journey["journey_id"],
                "capability_id": journey["capability_id"],
                "class": journey["class"],
                "oracle": journey["oracle"],
                "status": "pass" if passed else "missing",
                "evidence": redact(raw.get("evidence")) if isinstance(raw, dict) else None,
            }
        )
    return results


def build_runtime(repo_root: Path, evidence: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": "v2-runtime-artifact.v0",
        "host": socket.gethostname(),
        "platform": platform.platform(),
        "python": platform.python_version(),
        "machine": platform.machine(),
        "repo_root": str(repo_root),
        "git_commit": run_git(repo_root, "rev-parse", "HEAD"),
        "git_branch": run_git(repo_root, "rev-parse", "--abbrev-ref", "HEAD"),
        "git_dirty": bool(run_git(repo_root, "status", "--porcelain")),
        "environment": {
            "AGENTIC_PROFILE": os.environ.get("AGENTIC_PROFILE"),
            "AGENTIC_ROOT": os.environ.get("AGENTIC_ROOT"),
            "AGENTIC_COMPOSE_PROJECT": os.environ.get("AGENTIC_COMPOSE_PROJECT"),
            "external_telemetry": "disabled",
        },
        "evidence_runtime": redact(evidence.get("runtime", {})),
    }


def validate_artifact_bundle(artifact_dir: Path) -> None:
    for name in REQUIRED_ARTIFACTS:
        path = artifact_dir / name
        if not path.is_file():
            fail(f"missing evaluation artifact: {path}")
        if path.suffix == ".json":
            data = load_json(path)
            if not isinstance(data.get("schema_version"), str) or not data["schema_version"].startswith("v2-"):
                fail(f"{path} missing v2 schema_version")
    for subdir in ("logs", "traces", "attempts"):
        if not (artifact_dir / subdir).is_dir():
            fail(f"missing evaluation artifact directory: {artifact_dir / subdir}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the static v2 evaluation artifact writer.")
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT, help="Repository root containing evaluation/spec.")
    parser.add_argument("--artifact-root", type=Path, default=default_artifact_root(), help="Directory that receives <evaluation_id>/ artifacts.")
    parser.add_argument("--evaluation-id", help="Stable ID for this evaluation. Defaults to timestamp plus commit hash.")
    parser.add_argument("--campaign-id", default="manual-v2-static", help="Campaign ID recorded in evaluation.json.")
    parser.add_argument("--evidence-file", type=Path, help="JSON evidence file with gates and journeys objects.")
    parser.add_argument("--allow-overwrite", action="store_true", help="Allow replacing an existing evaluation directory.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    try:
        specs = spec_validator.validate_all(repo_root)
    except SystemExit as exc:
        return int(exc.code) if isinstance(exc.code, int) else 1

    evidence = load_json(args.evidence_file, required=False) if args.evidence_file else {}
    evidence = redact(evidence)

    candidate_commit = run_git(repo_root, "rev-parse", "HEAD") or "unknown"
    evaluation_id = args.evaluation_id or f"v2-static-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}-{short_hash(candidate_commit)}"
    if not EVALUATION_ID_PATTERN.match(evaluation_id):
        fail("evaluation id may contain only letters, numbers, '.', ':', '_' and '-'")

    artifact_dir = args.artifact_root.resolve() / evaluation_id
    if artifact_dir.exists() and not args.allow_overwrite:
        fail(f"evaluation artifact directory already exists: {artifact_dir}")
    artifact_dir.mkdir(parents=True, exist_ok=True)
    for subdir in ("logs", "traces", "attempts"):
        (artifact_dir / subdir).mkdir(exist_ok=True)

    started_at = now_utc()
    gates, reasons = validate_evidence(evidence, specs)
    journeys = build_journey_results(specs, evidence)
    passed_journeys = sum(1 for item in journeys if item["status"] == "pass")
    tpsr = passed_journeys / len(journeys) if journeys else 0.0
    decision = "pareto" if not reasons else "quarantine"
    status = "pass" if not reasons else "incomplete"

    runtime = build_runtime(repo_root, evidence)
    manifest = {
        "schema_version": "v2-evaluation-manifest.v0",
        "evaluation_id": evaluation_id,
        "campaign_id": args.campaign_id,
        "mode": "static",
        "local_only": True,
        "artifact_dir": str(artifact_dir),
        "spec_files": {name: str(path) for name, path in spec_validator.SPEC_FILES.items()},
        "corpus_id": specs["visible_corpus"]["corpus_id"],
        "corpus_version": specs["visible_corpus"]["corpus_version"],
        "candidate_commit": candidate_commit,
        "created_at": started_at,
    }
    gates_artifact = {
        "schema_version": "v2-gates-artifact.v0",
        "evaluation_id": evaluation_id,
        "status": status,
        "gates": gates,
        "reasons": reasons,
    }
    engineering = {
        "schema_version": "v2-engineering-artifact.v0",
        "evaluation_id": evaluation_id,
        "status": "not_run",
        "reason": "Initial runner only validates the static engineering corpus manifest.",
        "tasks": specs["engineering_corpus"]["tasks"],
    }
    pareto = {
        "schema_version": "v2-pareto-artifact.v0",
        "evaluation_id": evaluation_id,
        "status": "not_computed",
        "objectives": specs["metrics"].get("pareto_objectives", []),
        "reason": "No comparative candidate set exists in the initial static runner.",
    }
    recovery = {
        "schema_version": "v2-recovery-artifact.v0",
        "evaluation_id": evaluation_id,
        "status": "pass" if not reasons else "missing_evidence",
        "state_machine": specs["recovery"]["state_machine"],
        "campaign_artifacts": specs["recovery"]["campaign_artifacts"],
        "restore_must": specs["recovery"]["restore_must"],
    }
    evaluation = {
        "schema_version": "v2-evaluation-result.v0",
        "evaluation_id": evaluation_id,
        "campaign_id": args.campaign_id,
        "started_at": started_at,
        "finished_at": now_utc(),
        "status": status,
        "decision": decision,
        "candidate_commit": candidate_commit,
        "v1_commit": "f76778e342d43fdafaa17e05ad887f6e9853aa7d",
        "evaluator_commit": candidate_commit,
        "corpus": {
            "id": specs["visible_corpus"]["corpus_id"],
            "version": specs["visible_corpus"]["corpus_version"],
        },
        "runtime": {
            "platform": runtime["platform"],
            "machine": runtime["machine"],
            "python": runtime["python"],
        },
        "metrics": {
            "tpsr": tpsr,
            "journeys_total": len(journeys),
            "journeys_passed": passed_journeys,
            "confidence": specs["metrics"]["primary_metric"]["confidence"],
        },
        "gates": gates,
        "journeys": journeys,
        "reasons": reasons,
        "artifact_files": list(REQUIRED_ARTIFACTS),
    }

    report_lines = [
        f"# V2 Evaluation {evaluation_id}",
        "",
        f"- Status: `{status}`",
        f"- Decision: `{decision}`",
        f"- Candidate commit: `{candidate_commit}`",
        f"- TPSR: `{passed_journeys}/{len(journeys)}`",
        f"- Local only: `true`",
        "",
        "## Reasons",
    ]
    if reasons:
        report_lines.extend(f"- {reason}" for reason in reasons)
    else:
        report_lines.append("- All supplied P0 evidence passed.")
    report_lines.extend(["", "## Journeys"])
    report_lines.extend(f"- `{item['journey_id']}`: `{item['status']}`" for item in journeys)
    report_lines.append("")

    write_json(artifact_dir / "evaluation.json", evaluation)
    write_json(artifact_dir / "manifest.json", manifest)
    write_json(artifact_dir / "gates.json", gates_artifact)
    write_json(artifact_dir / "runtime.json", runtime | {"schema_version": "v2-runtime-artifact.v0", "evaluation_id": evaluation_id})
    write_json(artifact_dir / "engineering.json", engineering)
    write_json(artifact_dir / "pareto.json", pareto)
    write_json(artifact_dir / "recovery.json", recovery)
    (artifact_dir / "report.md").write_text("\n".join(report_lines), encoding="utf-8")
    validate_artifact_bundle(artifact_dir)

    print(f"evaluation_id={evaluation_id}")
    print(f"artifact_dir={artifact_dir}")
    print(f"decision={decision}")
    if reasons:
        for reason in reasons:
            print(f"reason={reason}")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
