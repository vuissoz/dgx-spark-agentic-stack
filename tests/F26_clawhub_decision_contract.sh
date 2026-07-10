#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

adr_file="${REPO_ROOT}/docs/decisions/ADR-0135-openclaw-clawhub-cli-exclusion.md"
[[ -s "${adr_file}" ]] || fail "missing ADR for the managed clawhub CLI decision: ${adr_file}"
grep -q 'intentionally does \*\*not\*\* install the standalone' "${adr_file}" \
  || fail "ADR must explicitly state that the managed OpenClaw runtime excludes the standalone clawhub CLI"
grep -q 'openclaw skills search' "${adr_file}" \
  || fail "ADR must document native openclaw catalog workflows"

doctor_file="${REPO_ROOT}/scripts/doctor.sh"
grep -q 'for required_domain in clawhub.ai www.clawhub.ai' "${doctor_file}" \
  || fail "doctor must keep validating the ClawHub allowlist contract"
grep -q 'openclaw skills search --json --limit 1 calendar' "${doctor_file}" \
  || fail "doctor must keep validating native OpenClaw ClawHub catalog access"

for doc_file in \
  "${REPO_ROOT}/docs/runbooks/openclaw-explained-beginners.en.md" \
  "${REPO_ROOT}/docs/runbooks/openclaw-explique-debutants.md"; do
  grep -q 'clawhub' "${doc_file}" \
    || fail "OpenClaw beginner docs must mention ClawHub usage guidance: ${doc_file}"
  grep -q 'openclaw skills search' "${doc_file}" \
    || fail "OpenClaw beginner docs must direct operators to native openclaw catalog commands: ${doc_file}"
done

if rg -n 'npm i -g clawhub|pnpm add -g clawhub|command -v clawhub|clawhub --help' \
  "${REPO_ROOT}/deployments" "${REPO_ROOT}/compose" "${REPO_ROOT}/scripts" >/tmp/agent-f26-clawhub-install-scan.out; then
  cat /tmp/agent-f26-clawhub-install-scan.out >&2
  fail "managed runtime sources must not install or require the standalone clawhub CLI"
fi

ok "F26_clawhub_decision_contract passed"
