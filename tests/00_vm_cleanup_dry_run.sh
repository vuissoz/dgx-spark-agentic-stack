#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

AGENT_BIN="${REPO_ROOT}/agent"
[[ -x "${AGENT_BIN}" ]] || fail "agent binary is missing or not executable"

out_file="$(mktemp)"
out_yes_file="$(mktemp)"
trap 'rm -f "${out_file}" "${out_yes_file}"' EXIT

if ! "${AGENT_BIN}" vm cleanup --dry-run --name cleanup-vm >"${out_file}" 2>&1; then
  cat "${out_file}" >&2 || true
  fail "agent vm cleanup --dry-run failed"
fi

grep -q '^DRY RUN - no changes applied\.$' "${out_file}" \
  || fail "dry-run output missing header"
grep -q '^name=cleanup-vm$' "${out_file}" \
  || fail "dry-run output missing VM name"
grep -q '^force=0$' "${out_file}" \
  || fail "dry-run output missing default force=0"
grep -q '^planned_steps=stop_if_running,delete$' "${out_file}" \
  || fail "dry-run output missing planned steps"
ok "agent vm cleanup dry-run basic contract is stable"

if ! "${AGENT_BIN}" vm cleanup --dry-run --name cleanup-vm --yes >"${out_yes_file}" 2>&1; then
  cat "${out_yes_file}" >&2 || true
  fail "agent vm cleanup --dry-run --yes failed"
fi

grep -q '^force=1$' "${out_yes_file}" \
  || fail "dry-run output missing force=1 when --yes is provided"
ok "agent vm cleanup --yes is reflected in dry-run output"

ok "00_vm_cleanup_dry_run passed"
