#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3
assert_cmd docker

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

suffix="v2-live-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_LLM_NETWORK="agentic-${suffix}-llm"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"
export OLLAMA_HOST_PORT="$(pick_free_loopback_port 31440)"
export OPENCLAW_WEBHOOK_HOST_PORT="$(pick_free_loopback_port 38120)"
export OPENCLAW_GATEWAY_HOST_PORT="$(pick_free_loopback_port 38795)"
export OPENCLAW_GATEWAY_PROXY_METRICS_PORT="$(pick_free_loopback_port 39120)"
export OPENCLAW_RELAY_HOST_PORT="$(pick_free_loopback_port 38130)"

live_evidence_file="${AGENTIC_ROOT}/deployments/test-reports/v2-live-proof/evidence.json"
drift_evidence_file="${AGENTIC_ROOT}/deployments/test-reports/v2-live-proof/duplicate-runtime.json"
combined_file="${AGENTIC_ROOT}/deployments/test-reports/v2-live-proof/combined.json"
artifact_root="${AGENTIC_ROOT}/deployments/test-reports/v2-live-proof/evaluations"
ready_doctor="${AGENTIC_ROOT}/tests/doctor-ready.sh"

cleanup() {
  "${agent_bin}" down core >/tmp/agent-v2-live-stack-down.out 2>&1 || true
  docker network rm "${AGENTIC_LLM_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_EGRESS_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_NETWORK}" >/dev/null 2>&1 || true
  if [[ -d "${AGENTIC_ROOT}" ]]; then
    docker run --rm \
      --user 0:0 \
      -v "${AGENTIC_ROOT}:/runtime" \
      --entrypoint /bin/sh \
      agentic/optional-modules:local \
      -c "chown -R $(id -u):$(id -g) /runtime" >/dev/null 2>&1 || true
    find "${AGENTIC_ROOT}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${AGENTIC_ROOT}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"${REPO_ROOT}/deployments/bootstrap/init_fs.sh"
cat >"${ready_doctor}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "OK: doctor result: READY"
SH
chmod +x "${ready_doctor}"
"${agent_bin}" up core >/tmp/agent-v2-live-stack-up-core.out \
  || fail "unable to start core stack for live v2 ownership proof"

core_services=(
  ollama
  ollama-gate
  gate-mcp
  openclaw
  openclaw-provider-bridge
  openclaw-gateway
  openclaw-sandbox
  openclaw-relay
  toolbox
  unbound
  egress-proxy
)

for service in "${core_services[@]}"; do
  cid="$(require_service_container "${service}")" || exit 1
  wait_for_container_ready "${cid}" 180 || fail "service '${service}' did not become ready"
done

"${agent_bin}" llm backend remote >/tmp/agent-v2-live-stack-backend.out \
  || fail "unable to set a coherent live backend policy before v2 ownership proof"

"${REPO_ROOT}/scripts/run_v2_live_single_source_of_truth.py" \
  --agentic-root "${AGENTIC_ROOT}" \
  --profile rootless-dev \
  --compose-project "${AGENTIC_COMPOSE_PROJECT}" \
  --output "${live_evidence_file}" >/tmp/agent-v2-live-stack-runner.out

python3 - "${live_evidence_file}" "${AGENTIC_ROOT}" "${AGENTIC_COMPOSE_PROJECT}" <<'PY'
import json
import pathlib
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
root = pathlib.Path(sys.argv[2])
compose_project = sys.argv[3]
gate = data["gates"]["p0-single-source-of-truth"]
assert gate["status"] == "pass"
assert gate["evidence"]["target_mode"] == "host-backed"
assert gate["evidence"]["require_live_stack"] is True
assert gate["evidence"]["fixture"]["agentic_root"] == str(root)
assert gate["evidence"]["fixture"]["bootstrapped_runtime_target"] is False
assert gate["evidence"]["domains"]["runtime_env"]["status"] == "pass"
assert gate["evidence"]["domains"]["active_release"]["status"] == "pass"
live = gate["evidence"]["domains"]["live_stack"]
assert live["status"] == "pass"
assert live["compose_project"] == compose_project
assert len(live["containers"]) >= 1
assert data["runtime"]["agentic_root"] == str(root)
PY
grep -q '^gate_status=pass$' /tmp/agent-v2-live-stack-runner.out \
  || fail "live runner must print a pass summary for the real stack"
ok "live single-source runner succeeds against a real temporary deployment"

"${REPO_ROOT}/scripts/aggregate_v2_evidence.py" \
  --run-bootstrap-doctor \
  --bootstrap-doctor-command "${ready_doctor}" \
  --single-source-agentic-root "${AGENTIC_ROOT}" \
  --single-source-profile rootless-dev \
  --single-source-compose-project "${AGENTIC_COMPOSE_PROJECT}" \
  --single-source-require-live-stack \
  --output "${combined_file}"

python3 - "${combined_file}" "${AGENTIC_ROOT}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
root = sys.argv[2]
gate = data["gates"]["p0-single-source-of-truth"]
assert gate["status"] == "pass"
producer = next(
    item for item in data["runtime"]["producers"]
    if item.get("producer") == "scripts/produce_v2_single_source_of_truth_evidence.py"
)
assert producer["status"] == "pass"
assert producer["agentic_root"] == root
assert producer["evidence_kind"] == "host_backed_runtime_contract_owner_probe"
PY

set +e
"${REPO_ROOT}/scripts/run_v2_evaluation.py" \
  --artifact-root "${artifact_root}" \
  --evaluation-id live-stack-runtime \
  --evidence-file "${combined_file}" >/tmp/agent-v2-live-stack-eval.out 2>&1
eval_rc=$?
set -e
[[ "${eval_rc}" -eq 0 ]] || fail "combined evaluation must accept live-stack ownership evidence"
grep -q '^decision=pareto$' /tmp/agent-v2-live-stack-eval.out \
  || fail "combined live-stack evaluation must produce pareto decision"
ok "combined evaluation accepts live stack ownership evidence"

set +e
"${REPO_ROOT}/scripts/produce_v2_single_source_of_truth_evidence.py" \
  --agentic-root "${AGENTIC_ROOT}" \
  --profile rootless-dev \
  --compose-project "${AGENTIC_COMPOSE_PROJECT}" \
  --require-live-stack \
  --unsafe-duplicate-runtime-key \
  --output "${drift_evidence_file}" >/tmp/agent-v2-live-stack-drift.out 2>&1
drift_rc=$?
set -e
[[ "${drift_rc}" -ne 0 ]] || fail "duplicate runtime ownership drift must fail against a live stack"
python3 - "${drift_evidence_file}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
gate = data["gates"]["p0-single-source-of-truth"]
assert gate["status"] == "fail"
assert gate["evidence"]["domains"]["runtime_env"]["status"] == "fail"
assert "AGENTIC_LLM_BACKEND" in gate["evidence"]["domains"]["runtime_env"]["duplicate_keys"]
assert gate["evidence"]["domains"]["live_stack"]["status"] == "pass"
PY
ok "live single-source evidence fails closed on contradictory runtime ownership"

ok "V2_live_single_source_stack_integration passed"
