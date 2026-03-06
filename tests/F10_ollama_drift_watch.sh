#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F10 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

suffix="f10-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"

fixture_src="${SCRIPT_DIR}/fixtures/ollama-drift"
[[ -d "${fixture_src}" ]] || fail "fixture directory missing: ${fixture_src}"

fixture_tmp="$(mktemp -d)"
state_dir="${AGENTIC_ROOT}/deployments/ollama-drift-test"

cleanup() {
  rm -rf "${fixture_tmp}" >/dev/null 2>&1 || true
  if [[ -d "${AGENTIC_ROOT}" ]]; then
    rm -rf "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cp -R "${fixture_src}/." "${fixture_tmp}/"

set +e
"${agent_bin}" ollama-drift watch --no-beads --sources-dir "${fixture_tmp}" --state-dir "${state_dir}" >/tmp/agent-f10-run1.out 2>&1
rc1=$?
set -e
[[ "${rc1}" -eq 0 ]] || {
  cat /tmp/agent-f10-run1.out >&2
  fail "initial drift watch run should pass with valid fixtures"
}
grep -q 'no drift detected' /tmp/agent-f10-run1.out || fail "watch output should confirm no drift"
[[ -s "${state_dir}/baseline/openai.mdx" ]] || fail "baseline for openai should be created"
[[ -s "${state_dir}/latest-report.json" ]] || fail "latest JSON report should be generated"
ok "initial drift watch run passes and creates baseline"

set +e
"${agent_bin}" ollama-drift watch --no-beads --sources-dir "${fixture_tmp}" --state-dir "${state_dir}" >/tmp/agent-f10-run2.out 2>&1
rc2=$?
set -e
[[ "${rc2}" -eq 0 ]] || {
  cat /tmp/agent-f10-run2.out >&2
  fail "second drift watch run should stay green without changes"
}
ok "second drift watch run stays green"

sed -i '/\/v1\/responses/d' "${fixture_tmp}/openai.mdx"
set +e
"${agent_bin}" ollama-drift watch --no-beads --sources-dir "${fixture_tmp}" --state-dir "${state_dir}" >/tmp/agent-f10-run3.out 2>&1
rc3=$?
set -e
[[ "${rc3}" -eq 2 ]] || {
  cat /tmp/agent-f10-run3.out >&2
  fail "drift watch should exit 2 on invariant drift"
}
grep -q 'drift detected' /tmp/agent-f10-run3.out || fail "drift output should be explicit"
grep -q 'openai:missing:/v1/responses' "${state_dir}/latest-report.txt" \
  || fail "report should include missing openai invariant"
ok "drift watch fails explicitly when invariants change"

set +e
"${agent_bin}" ollama-drift schedule --dry-run --force-cron --cron '0 5 * * 1' >/tmp/agent-f10-schedule.out 2>&1
schedule_rc=$?
set -e
[[ "${schedule_rc}" -eq 0 ]] || {
  cat /tmp/agent-f10-schedule.out >&2
  fail "schedule dry-run should succeed"
}
grep -q 'dry-run' /tmp/agent-f10-schedule.out || fail "schedule dry-run output missing marker"
grep -q '0 5 \* \* 1' /tmp/agent-f10-schedule.out || fail "schedule dry-run should print cron expression"
ok "schedule dry-run contract is stable"

ok "F10_ollama_drift_watch passed"
