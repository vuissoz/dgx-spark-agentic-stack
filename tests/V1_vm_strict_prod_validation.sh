#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_V_TESTS:-0}" == "1" ]]; then
  ok "V1 skipped because AGENTIC_SKIP_V_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

dry_run_out="$(mktemp)"
dry_run_all_out="$(mktemp)"
invalid_out="$(mktemp)"
trap 'rm -f "${dry_run_out}" "${dry_run_all_out}" "${invalid_out}"' EXIT

if ! "${agent_bin}" vm test --dry-run \
  --name test-vm \
  --workspace-path /home/ubuntu/test-stack \
  --test-selectors A,C,K \
  --allow-no-gpu >"${dry_run_out}" 2>&1; then
  cat "${dry_run_out}" >&2 || true
  fail "agent vm test dry-run failed"
fi

grep -q '^DRY RUN - no changes applied\.$' "${dry_run_out}" \
  || fail "dry-run output missing header"
grep -q '^name=test-vm$' "${dry_run_out}" \
  || fail "dry-run output missing VM name"
grep -q '^workspace_path=/home/ubuntu/test-stack$' "${dry_run_out}" \
  || fail "dry-run output missing workspace path"
grep -q '^test_selectors=A,C,K$' "${dry_run_out}" \
  || fail "dry-run output missing selectors"
grep -q '^require_gpu=0$' "${dry_run_out}" \
  || fail "dry-run output missing require_gpu=0 for --allow-no-gpu"
ok "agent vm test dry-run contract is stable"

if ! "${agent_bin}" vm test --dry-run --test-selectors all --allow-no-gpu >"${dry_run_all_out}" 2>&1; then
  cat "${dry_run_all_out}" >&2 || true
  fail "agent vm test --test-selectors all dry-run failed"
fi

grep -q '^test_selectors=A,B,C,D,E,F,G,H,I,J,K,L$' "${dry_run_all_out}" \
  || fail "selector expansion for all is incorrect"
ok "agent vm test expands all selector to A..L"

set +e
"${agent_bin}" vm test --dry-run --test-selectors Z >"${invalid_out}" 2>&1
rc=$?
set -e

[[ "${rc}" -ne 0 ]] || fail "agent vm test must reject invalid selector"
grep -Eqi 'Invalid test selector|A\.\.L|all' "${invalid_out}" \
  || fail "invalid selector failure output is not explicit enough"
ok "agent vm test rejects invalid selectors explicitly"

ok "V1_vm_strict_prod_validation passed"
