#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K0 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

profile_output="$("${agent_bin}" profile 2>/dev/null || true)"
if [[ "${AGENTIC_PROFILE:-}" == "rootless-dev" ]] || \
  grep -q '^profile=rootless-dev$' <<<"${profile_output}"; then
  ok "K0 strict gating scenario skipped in rootless-dev profile"
  exit 0
fi

assert_cmd docker

AGENTIC_DOCKER_USER_CHAIN=AGENTIC-K0-MISSING "${agent_bin}" up optional >/tmp/agent-k0-gate-fail.out 2>&1 \
  || fail "agent up optional should continue when doctor is red"
grep -Eqi 'doctor is not green|doctor|not green' /tmp/agent-k0-gate-fail.out \
  || fail "optional doctor warning output is not explicit enough"
ok "agent up optional warns when doctor is red and continues"

"${agent_bin}" doctor >/tmp/agent-k0-doctor.out \
  || fail "precondition failed: doctor must be green before validating optional happy-path"

"${agent_bin}" up optional >/tmp/agent-k0-up.out \
  || fail "agent up optional failed while doctor is green"

optional_cid="$(require_service_container optional-sentinel)" || exit 1
wait_for_container_ready "${optional_cid}" 60 || fail "optional-sentinel did not become ready"
ok "optional profile deployment succeeds when doctor is green"

ok "K0_optional_gating passed"
