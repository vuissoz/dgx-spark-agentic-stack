#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

compose_file="${REPO_ROOT}/compose/compose.ui.yml"
doctor_file="${REPO_ROOT}/scripts/doctor.sh"
runbook_file="${REPO_ROOT}/docs/runbooks/git-forge-management.md"

[[ -f "${compose_file}" ]] || fail "missing compose file"
[[ -f "${doctor_file}" ]] || fail "missing doctor script"
[[ -f "${runbook_file}" ]] || fail "missing git-forge runbook"

mapfile -t exception_services < <(agentic_readwrite_rootfs_exception_services)
printf '%s\n' "${exception_services[@]}" | grep -qx 'optional-forgejo' \
  || fail "optional-forgejo must remain in the writable-rootfs exception list"

reason="$(agentic_service_readwrite_rootfs_exception_reason optional-forgejo || true)"
[[ -n "${reason}" ]] || fail "optional-forgejo must have a documented writable-rootfs reason"
[[ "${reason}" == *"Forgejo rootless"* ]] || fail "unexpected Forgejo writable-rootfs reason: ${reason}"

python3 - "${compose_file}" <<'PY'
import sys
from pathlib import Path

compose_path = Path(sys.argv[1])
lines = compose_path.read_text(encoding="utf-8").splitlines()
service_index = next(
    (idx for idx, line in enumerate(lines) if line.strip() == "optional-forgejo:"),
    None,
)
if service_index is None:
    raise SystemExit("optional-forgejo service block is missing from compose.ui.yml")
window = lines[service_index:service_index + 90]
if any("read_only:" in line and "true" in line for line in window):
    raise SystemExit("optional-forgejo must not declare read_only: true in compose.ui.yml")
if not any("Intentionally no read_only" in line for line in window[:8]):
    raise SystemExit("optional-forgejo compose block must document the writable-rootfs exception inline")
PY

grep -q "uses the documented writable-rootfs exception" "${doctor_file}" \
  || fail "doctor must report the documented writable-rootfs exception explicitly"
grep -q "agentic_service_readwrite_rootfs_exception_reason" "${doctor_file}" \
  || fail "doctor must source the explicit writable-rootfs exception reason"

grep -q '`optional-forgejo` keeps the standard hardening baseline' "${runbook_file}" \
  || fail "git-forge runbook must document the writable-rootfs exception"
grep -q '`./agent doctor` reports the exception as documented' "${runbook_file}" \
  || fail "git-forge runbook must mention doctor's explicit exception handling"

ok "F21_forgejo_rootfs_exception_contract passed"
