#!/usr/bin/env python3
"""Run v2 single-source-of-truth evidence against a live runtime target."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[0]
PRODUCER = SCRIPT_DIR / "produce_v2_single_source_of_truth_evidence.py"
AGENT_BIN = REPO_ROOT / "agent"


def now_stamp() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def run_cmd(args: list[str], cwd: Path, timeout_sec: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout_sec,
        check=False,
    )


def parse_profile_output(output: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key] = value
    return data


def detect_runtime() -> dict[str, str]:
    proc = run_cmd([str(AGENT_BIN), "profile"], REPO_ROOT, 30)
    if proc.returncode != 0:
        raise SystemExit(f"failed to detect runtime via './agent profile': {proc.stderr.strip() or proc.stdout.strip()}")
    data = parse_profile_output(proc.stdout)
    required = {"profile", "root", "compose_project"}
    missing = sorted(required - set(data))
    if missing:
        raise SystemExit(f"'./agent profile' missing keys: {', '.join(missing)}")
    return data


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run v2 single-source-of-truth evidence against a live runtime target.")
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--agentic-root", type=Path, help="Override the runtime root; defaults to './agent profile' root.")
    parser.add_argument("--profile", choices=("rootless-dev", "strict-prod"), help="Override the runtime profile; defaults to './agent profile'.")
    parser.add_argument("--compose-project", help="Override the compose project; defaults to './agent profile'.")
    parser.add_argument("--output", type=Path, help="Write evidence JSON to this path instead of the default report location.")
    parser.add_argument("--timeout-sec", type=int, default=60)
    parser.add_argument("--bootstrap-runtime-target", action="store_true", help="Bootstrap the target root before inspection.")
    return parser.parse_args()


def default_output(agentic_root: Path) -> Path:
    return agentic_root / "deployments" / "test-reports" / "v2-single-source-of-truth" / now_stamp() / "evidence.json"


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    if args.agentic_root and args.profile and args.compose_project:
        detected: dict[str, str] = {}
        agentic_root = args.agentic_root.resolve()
        profile = args.profile
        compose_project = args.compose_project
    else:
        detected = detect_runtime()
        agentic_root = args.agentic_root.resolve() if args.agentic_root else Path(detected["root"]).resolve()
        profile = args.profile or detected["profile"]
        compose_project = args.compose_project or detected["compose_project"]
    output_path = args.output.resolve() if args.output else default_output(agentic_root)

    cmd = [
        str(PRODUCER),
        "--repo-root",
        str(repo_root),
        "--agentic-root",
        str(agentic_root),
        "--profile",
        profile,
        "--compose-project",
        compose_project,
        "--require-live-stack",
        "--output",
        str(output_path),
    ]
    if args.bootstrap_runtime_target:
        cmd.append("--bootstrap-runtime-target")

    proc = run_cmd(cmd, repo_root, args.timeout_sec)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        sys.stdout.write(proc.stdout)
        return proc.returncode

    payload: dict[str, Any] = json.loads(output_path.read_text(encoding="utf-8"))
    gate = payload["gates"]["p0-single-source-of-truth"]
    live_stack = gate["evidence"]["domains"].get("live_stack", {})
    print(f"output={output_path}")
    print(f"target_root={agentic_root}")
    print(f"profile={profile}")
    print(f"compose_project={compose_project}")
    print(f"gate_status={gate['status']}")
    print(f"live_stack_containers={len(live_stack.get('containers', []))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
