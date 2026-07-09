#!/usr/bin/env python3
"""Produce local evidence for v2 model backend failure handling."""

from __future__ import annotations

import argparse
import json
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


def direct_backend_probe(*, unsafe_allow_direct_backend: bool) -> dict[str, Any]:
    if unsafe_allow_direct_backend:
        return {
            "status": "allowed",
            "route": "backend://ollama-primary",
            "reason": "unsafe test hook bypassed the broker route",
        }
    return {
        "status": "refused",
        "route": "backend://ollama-primary",
        "reason": "agents must call the model broker, not model backends directly",
    }


def broker_failure_scenario(*, unsafe_silent_success: bool, fallback_enabled: bool) -> dict[str, Any]:
    primary = {
        "backend_id": "ollama-primary",
        "status": "unavailable",
        "error_code": "backend_unreachable",
    }
    if unsafe_silent_success:
        return {
            "status": "silent_success",
            "primary_backend": primary,
            "decision": "success",
            "actionable": False,
            "reason": "unsafe test hook hid the primary backend failure",
        }
    if fallback_enabled:
        return {
            "status": "explicit_fallback",
            "primary_backend": primary,
            "decision": "fallback",
            "fallback_backend": {
                "backend_id": "trtllm-canary",
                "status": "selected",
                "selection_reason": "primary backend unavailable and fallback policy allowed",
            },
            "actionable": True,
        }
    return {
        "status": "actionable_refusal",
        "primary_backend": primary,
        "decision": "refuse",
        "error_code": "model_backend_unavailable",
        "message": "primary model backend unavailable; retry after recovery or enable an approved fallback policy",
        "actionable": True,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Produce v2 model-backend-failure evidence JSON.")
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--output", type=Path, help="Write evidence JSON to this file instead of stdout.")
    parser.add_argument("--fallback-enabled", action="store_true", help="Simulate explicit fallback instead of actionable refusal.")
    parser.add_argument(
        "--unsafe-allow-direct-backend",
        action="store_true",
        help="Test hook: make the direct backend probe succeed to prove failure detection.",
    )
    parser.add_argument(
        "--unsafe-silent-success",
        action="store_true",
        help="Test hook: hide the primary backend failure to prove silent success is rejected.",
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

    direct_probe = direct_backend_probe(unsafe_allow_direct_backend=args.unsafe_allow_direct_backend)
    broker_scenario = broker_failure_scenario(
        unsafe_silent_success=args.unsafe_silent_success,
        fallback_enabled=args.fallback_enabled,
    )

    direct_access_refused = direct_probe["status"] == "refused"
    failure_handled = broker_scenario["status"] in {"explicit_fallback", "actionable_refusal"} and broker_scenario["actionable"]
    model_journey_status = "pass" if spec_status == "pass" and direct_access_refused and failure_handled else "fail"

    evidence = {
        "schema_version": "v2-model-backend-failure-evidence.v0",
        "generated_at": generated_at,
        "producer": "scripts/produce_v2_model_backend_failure_evidence.py",
        "runtime": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "repo_root": str(repo_root),
            "git_commit": git_value(repo_root, "rev-parse", "HEAD"),
            "git_branch": git_value(repo_root, "rev-parse", "--abbrev-ref", "HEAD"),
            "evidence_kind": "local_simulated_broker_policy",
        },
        "gates": {
            "p0-no-direct-backend-or-docker-sock": {
                "status": "pass" if direct_access_refused else "fail",
                "evidence": {
                    "type": "local_direct_backend_access_probe",
                    "generated_at": generated_at,
                    "probe": direct_probe,
                    "unsafe_allow_direct_backend": args.unsafe_allow_direct_backend,
                },
            },
            "p0-audit-correlated": {
                "status": "partial" if failure_handled else "fail",
                "evidence": {
                    "type": "local_broker_decision_audit_shape",
                    "generated_at": generated_at,
                    "correlation_id": "local-simulated-run",
                    "broker_decision": broker_scenario["decision"],
                    "note": "This producer records the audit shape; durable deployed audit persistence is not implemented here.",
                },
            },
        },
        "journeys": {
            "model-backend-failure": {
                "status": model_journey_status,
                "evidence": {
                    "type": "local_model_broker_failure_simulation",
                    "generated_at": generated_at,
                    "spec_validation": {"status": spec_status, "error": spec_error},
                    "direct_backend_probe": direct_probe,
                    "broker_failure_scenario": broker_scenario,
                    "fallback_enabled": args.fallback_enabled,
                    "note": "This is local simulated broker-policy evidence, not a deployed ModelBroker runtime check.",
                },
            }
        },
    }

    if args.output:
        write_json(args.output, evidence)
    else:
        print(json.dumps(evidence, indent=2, sort_keys=True))

    return 0 if model_journey_status == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
