#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

AGENT_BIN="${REPO_ROOT}/agent"
[[ -x "${AGENT_BIN}" ]] || fail "agent binary is missing or not executable"

out_file="$(mktemp)"
trap 'rm -f "${out_file}"' EXIT

if ! "${AGENT_BIN}" vm create --dry-run --name test-vm --cpus 4 --memory 16G --disk 80G >"${out_file}" 2>&1; then
  cat "${out_file}" >&2 || true
  fail "agent vm create --dry-run failed"
fi

grep -q '^DRY RUN - no changes applied\.$' "${out_file}" \
  || fail "dry-run output missing header"
grep -q '^name=test-vm$' "${out_file}" \
  || fail "dry-run output missing VM name"
grep -q '^cpus=4$' "${out_file}" \
  || fail "dry-run output missing CPU value"
grep -q '^memory=16G$' "${out_file}" \
  || fail "dry-run output missing memory value"
grep -q '^disk=80G$' "${out_file}" \
  || fail "dry-run output missing disk value"

ok "agent vm create dry-run works"
ok "00_vm_create_dry_run passed"
