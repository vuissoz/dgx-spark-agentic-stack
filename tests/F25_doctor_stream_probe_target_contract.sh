#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

python3 - "${REPO_ROOT}" <<'PY' || fail "doctor streamed-probe target contract drifted"
import re
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
doctor_path = repo_root / "scripts" / "doctor.sh"
doctor_source = doctor_path.read_text(encoding="utf-8")

targets_match = re.search(
    r'local -a targets=\(\n(?P<body>.*?)\n  \)',
    doctor_source,
    re.S,
)
if not targets_match:
    raise SystemExit("unable to locate streamed tool-call targets array in scripts/doctor.sh")

targets = []
for raw_line in targets_match.group("body").splitlines():
    line = raw_line.strip()
    if not line or not line.startswith('"') or "|" not in line:
        continue
    tool, service = line.strip('"').split("|", 1)
    targets.append((tool, service))

if not targets:
    raise SystemExit("streamed tool-call targets array is empty")

expected_openclaw = ("openclaw", "openclaw")
if expected_openclaw not in targets:
    raise SystemExit(
        "streamed tool-call targets must keep the canonical OpenClaw mapping "
        "'openclaw|openclaw'"
    )

compose_services: set[str] = set()
for compose_path in sorted((repo_root / "compose").glob("compose*.yml")):
    in_services = False
    for raw_line in compose_path.read_text(encoding="utf-8").splitlines():
        if raw_line.startswith("services:"):
            in_services = True
            continue
        if not in_services:
            continue
        if raw_line and not raw_line.startswith(" "):
            break
        if raw_line.startswith("  ") and not raw_line.startswith("    "):
            stripped = raw_line.strip()
            if stripped.endswith(":"):
                compose_services.add(stripped[:-1])

missing = [(tool, service) for tool, service in targets if service not in compose_services]
if missing:
    rendered = ", ".join(f"{tool}|{service}" for tool, service in missing)
    raise SystemExit(
        f"streamed tool-call targets reference unknown compose services: {rendered}"
    )
PY

ok "F25_doctor_stream_probe_target_contract passed"
