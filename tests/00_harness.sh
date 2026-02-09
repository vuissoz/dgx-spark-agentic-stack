#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

AGENT_BIN="${REPO_ROOT}/agent"
[[ -x "${AGENT_BIN}" ]] || fail "agent binary is missing or not executable"

marker_file="$(mktemp)"
doctor_output="$(mktemp)"
isolated_tests_dir="$(mktemp -d)"
trap 'rm -f "${marker_file}" "${doctor_output}"; rm -rf "${isolated_tests_dir}"' EXIT

cat > "${isolated_tests_dir}/A_smoke.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${AGENT_TEST_MARKER:-}" ]]; then
  : >"${AGENT_TEST_MARKER}"
fi
EOF
chmod +x "${isolated_tests_dir}/A_smoke.sh"
AGENTIC_TEST_DIR="${isolated_tests_dir}" AGENT_TEST_MARKER="${marker_file}" "${AGENT_BIN}" test A
[[ -f "${marker_file}" ]] || fail "agent test A did not execute an A_* test script"
ok "agent test A executes A_* scripts"

set +e
AGENTIC_COMPOSE_PROJECT="agentic-step0-harness-nonexistent" "${AGENT_BIN}" doctor >"${doctor_output}" 2>&1
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "agent doctor must fail when no compose stack is deployed"
grep -Eqi 'not ready|not deployed|no containers' "${doctor_output}" || fail "doctor output is not explicit enough in not-ready mode"
ok "agent doctor fails explicitly when no compose stack is deployed"

ok "00_harness passed"
