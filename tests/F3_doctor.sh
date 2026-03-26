#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F3 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

if [[ "${AGENTIC_PROFILE:-strict-prod}" == "rootless-dev" ]]; then
  ok "F3 skipped in rootless-dev profile (strict DOCKER-USER assertions are strict-prod only)"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd python3

if [[ ! -s "${AGENTIC_ROOT:-/srv/agentic}/deployments/current/images.json" ]]; then
  if ! "${agent_bin}" update >/tmp/agent-f3-update.out 2>&1; then
    cat /tmp/agent-f3-update.out >&2
    fail "unable to prepare release snapshot for nominal doctor run (run 'agent update' with proper permissions first)"
  fi
fi

"${agent_bin}" doctor >/tmp/agent-f3-doctor-nominal.out \
  || fail "agent doctor failed in nominal state"
grep -q "default model '.*' executes a direct tool-call probe through ollama-gate" /tmp/agent-f3-doctor-nominal.out \
  || fail "doctor nominal output must include the default model tool-call probe"
grep -q "llm backend policy '.*' runtime effective='.*' cooldown=.* state=" /tmp/agent-f3-doctor-nominal.out \
  || fail "doctor nominal output must include the llm backend runtime policy check"
ok "doctor passes in nominal state"

tmp_server_log="$(mktemp)"
server_pid=""
cleanup() {
  if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" >/dev/null 2>&1; then
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  rm -f "${tmp_server_log}"
}
trap cleanup EXIT

python3 -m http.server 11888 --bind 0.0.0.0 >"${tmp_server_log}" 2>&1 &
server_pid="$!"
sleep 1

set +e
AGENTIC_DOCTOR_CRITICAL_PORTS=11888 "${agent_bin}" doctor >/tmp/agent-f3-doctor-bind.out 2>&1
bind_rc=$?
set -e

[[ "${bind_rc}" -ne 0 ]] || fail "doctor must fail when a critical port is exposed on 0.0.0.0"
grep -Eqi 'critical ports|non-loopback|exposed' /tmp/agent-f3-doctor-bind.out \
  || fail "doctor bind failure output is not explicit enough"
ok "doctor fails when a critical port is exposed publicly"

set +e
AGENTIC_DOCKER_USER_CHAIN=AGENTIC-DOCTOR-MISSING "${agent_bin}" doctor >/tmp/agent-f3-doctor-docker-user.out 2>&1
chain_rc=$?
set -e

[[ "${chain_rc}" -ne 0 ]] || fail "doctor must fail when DOCKER-USER enforcement chain is missing"
grep -Eqi 'DOCKER-USER|missing|incomplete' /tmp/agent-f3-doctor-docker-user.out \
  || fail "doctor DOCKER-USER failure output is not explicit enough"
ok "doctor fails when DOCKER-USER policy is missing"

ok "F3_doctor passed"
