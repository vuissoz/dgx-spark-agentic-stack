#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F17 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd python3

suffix="f17-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_LLM_NETWORK="agentic-${suffix}-llm"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"
export OLLAMA_HOST_PORT="$((20000 + (RANDOM % 10000)))"
export OPENCLAW_WEBHOOK_HOST_PORT="$((30000 + (RANDOM % 10000)))"
export OPENCLAW_RELAY_HOST_PORT="$((40000 + (RANDOM % 10000)))"
export OPENCLAW_GATEWAY_HOST_PORT="$((50000 + (RANDOM % 1000)))"
export OPENCLAW_GATEWAY_PROXY_METRICS_PORT="$((51000 + (RANDOM % 1000)))"

cleanup() {
  "${agent_bin}" down core >/tmp/agent-f17-down.out 2>&1 || true
  docker network rm "${AGENTIC_EGRESS_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_LLM_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_NETWORK}" >/dev/null 2>&1 || true
  if [[ -d "${AGENTIC_ROOT}" ]]; then
    find "${AGENTIC_ROOT}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${AGENTIC_ROOT}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"${REPO_ROOT}/deployments/bootstrap/init_fs.sh" >/tmp/agent-f17-initfs.out
"${agent_bin}" up core >/tmp/agent-f17-up-core.out \
  || fail "agent up core failed in F17"
"${REPO_ROOT}/deployments/releases/snapshot.sh" \
  --reason f17-hermetic-rollback \
  "${REPO_ROOT}/compose/compose.core.yml" >/tmp/agent-f17-snapshot.out \
  || fail "release snapshot creation failed in F17"

current_link="${AGENTIC_ROOT}/deployments/current"
if [[ ! -L "${current_link}" ]]; then
  fail "snapshot did not create current release symlink"
fi
release_dir="$(readlink -f "${current_link}")"
release_id="$(basename "${release_dir}")"
if [[ -z "${release_id}" ]]; then
  fail "unable to resolve current release id"
fi
if [[ ! -s "${release_dir}/images.json" ]]; then
  fail "release ${release_id} is missing images.json"
fi
if [[ ! -s "${release_dir}/compose.effective.yml" ]]; then
  fail "release ${release_id} is missing compose.effective.yml"
fi
ok "release ${release_id} contains snapshot artifacts required for hermetic rollback"

cat >"${release_dir}/compose.files" <<'EOF'
/nonexistent/repo/compose.core.yml
/nonexistent/repo/compose.agents.yml
EOF
ok "release ${release_id} compose.files deliberately invalidated"

set +e
rollback_output="$("${agent_bin}" rollback all "${release_id}" 2>&1)"
rollback_rc=$?
set -e
if [[ "${rollback_rc}" -ne 0 ]]; then
  printf '%s\n' "${rollback_output}" >&2
  fail "agent rollback all ${release_id} failed after compose.files invalidation"
fi

printf '%s\n' "${rollback_output}" | grep -Fq "rollback completed to release=${release_id}" \
  || fail "rollback output did not confirm restored release ${release_id}"
ok "rollback completed from release artifacts despite invalid compose.files"

for service in ollama ollama-gate egress-proxy unbound toolbox; do
  cid="$(service_container_id "${service}")"
  [[ -n "${cid}" ]] || continue
  wait_for_container_ready "${cid}" 120 || fail "service ${service} is not ready after hermetic rollback"
done
ok "critical services are healthy after hermetic rollback"

ok "F17_rollback_artifact_hermetic passed"
