#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

evidence_file="${tmp_dir}/single-source-evidence.json"
host_target_evidence_file="${tmp_dir}/single-source-host-target-evidence.json"
artifact_root="${tmp_dir}/artifacts/evaluations"
host_root="${tmp_dir}/host-root"
duplicate_host_root="${tmp_dir}/host-root-duplicate"
shadow_host_root="${tmp_dir}/host-root-shadow"
live_host_root="${tmp_dir}/host-root-live"
fake_bin="${tmp_dir}/fake-bin"

mkdir -p "${fake_bin}"
cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "ps" ]]; then
  project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --filter)
        if [[ "${2:-}" == label=com.docker.compose.project=* ]]; then
          project="${2#label=com.docker.compose.project=}"
        fi
        shift 2
        ;;
      --format)
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  if [[ "${project}" == "agentic-live-proof" ]]; then
    printf '%s\n' 'agentic-live-proof-ollama-gate-1|Up 2 minutes'
  fi
  exit 0
fi
echo "unexpected docker args: $*" >&2
exit 9
SH
chmod +x "${fake_bin}/docker"

"${REPO_ROOT}/scripts/produce_v2_single_source_of_truth_evidence.py" --output "${evidence_file}"
python3 - "${evidence_file}" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema_version"] == "v2-single-source-of-truth-evidence.v0"
gate = data["gates"]["p0-single-source-of-truth"]
assert gate["status"] == "pass"
assert gate["evidence"]["authoritative"] is True
domains = gate["evidence"]["domains"]
assert set(domains) == {"runtime_env", "llm_backend_policy", "llm_backend_runtime", "active_release"}
assert all(item["status"] == "pass" for item in domains.values())
assert gate["evidence"]["agent_command"]["status"] == "pass"
assert gate["evidence"]["target_mode"] == "disposable-fixture"
PY
ok "single-source-of-truth producer writes runtime-backed ownership evidence"

"${REPO_ROOT}/scripts/produce_v2_single_source_of_truth_evidence.py" \
  --agentic-root "${host_root}" \
  --bootstrap-runtime-target \
  --output "${host_target_evidence_file}"
python3 - "${host_target_evidence_file}" "${host_root}" <<'PY'
import json
import pathlib
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
host_root = pathlib.Path(sys.argv[2])
gate = data["gates"]["p0-single-source-of-truth"]
assert gate["status"] == "pass"
assert gate["evidence"]["target_mode"] == "host-backed"
assert gate["evidence"]["fixture"]["agentic_root"] == str(host_root)
assert gate["evidence"]["fixture"]["bootstrapped_runtime_target"] is True
assert data["runtime"]["evidence_kind"] == "host_backed_runtime_contract_owner_probe"
PY
ok "single-source-of-truth producer supports host-backed runtime targets"

PATH="${fake_bin}:$PATH" "${REPO_ROOT}/scripts/produce_v2_single_source_of_truth_evidence.py" \
  --agentic-root "${live_host_root}" \
  --compose-project agentic-live-proof \
  --bootstrap-runtime-target \
  --require-live-stack \
  --output "${tmp_dir}/live-stack-evidence.json"
python3 - "${tmp_dir}/live-stack-evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
gate = data["gates"]["p0-single-source-of-truth"]
assert gate["status"] == "pass"
live = gate["evidence"]["domains"]["live_stack"]
assert live["status"] == "pass"
assert len(live["containers"]) == 1
PY
ok "single-source-of-truth producer can require a live stack"

set +e
"${REPO_ROOT}/scripts/produce_v2_single_source_of_truth_evidence.py" \
  --agentic-root "${tmp_dir}/inactive-live-root" \
  --bootstrap-runtime-target \
  --require-live-stack \
  --output "${tmp_dir}/inactive-live-evidence.json" >/tmp/agent-v2-sot-live-fail.out 2>&1
inactive_live_rc=$?
set -e
[[ "${inactive_live_rc}" -ne 0 ]] || fail "inactive live-stack target must fail evidence production"
python3 - "${tmp_dir}/inactive-live-evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
gate = data["gates"]["p0-single-source-of-truth"]
assert gate["status"] == "fail"
live = gate["evidence"]["domains"]["live_stack"]
assert live["status"] == "fail"
assert live["error"]
PY
ok "single-source-of-truth producer fails closed when live stack is absent"

set +e
"${REPO_ROOT}/scripts/run_v2_evaluation.py" \
  --artifact-root "${artifact_root}" \
  --evaluation-id single-source-produced \
  --evidence-file "${evidence_file}" >/tmp/agent-v2-sot-eval.out 2>&1
eval_rc=$?
set -e
[[ "${eval_rc}" -eq 2 ]] || fail "single-source-only evidence must keep full evaluator in quarantine"
grep -q '^decision=quarantine$' /tmp/agent-v2-sot-eval.out \
  || fail "single-source-only evidence must produce quarantine decision"
python3 - "${artifact_root}/single-source-produced/evaluation.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert any("bootstrap-doctor" in reason for reason in data["reasons"])
PY
ok "static evaluator consumes single-source-of-truth evidence"

set +e
"${REPO_ROOT}/scripts/produce_v2_single_source_of_truth_evidence.py" \
  --agentic-root "${duplicate_host_root}" \
  --bootstrap-runtime-target \
  --unsafe-duplicate-runtime-key \
  --output "${tmp_dir}/duplicate-runtime-evidence.json" >/tmp/agent-v2-sot-duplicate.out 2>&1
duplicate_rc=$?
set -e
[[ "${duplicate_rc}" -ne 0 ]] || fail "duplicate runtime key must fail evidence production"
python3 - "${tmp_dir}/duplicate-runtime-evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
gate = data["gates"]["p0-single-source-of-truth"]
assert gate["status"] == "fail"
dupes = gate["evidence"]["domains"]["runtime_env"]["duplicate_keys"]
assert "AGENTIC_LLM_BACKEND" in dupes
PY
ok "single-source-of-truth producer detects duplicate runtime key ownership"

set +e
"${REPO_ROOT}/scripts/produce_v2_single_source_of_truth_evidence.py" \
  --agentic-root "${shadow_host_root}" \
  --bootstrap-runtime-target \
  --unsafe-shadow-owner-file \
  --output "${tmp_dir}/shadow-owner-evidence.json" >/tmp/agent-v2-sot-shadow.out 2>&1
shadow_rc=$?
set -e
[[ "${shadow_rc}" -ne 0 ]] || fail "shadow owner file must fail evidence production"
python3 - "${tmp_dir}/shadow-owner-evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
gate = data["gates"]["p0-single-source-of-truth"]
assert gate["status"] == "fail"
candidates = gate["evidence"]["domains"]["llm_backend_policy"]["owner_candidates"]
assert "gate/state/llm_backend.shadow.json" in candidates
PY
ok "single-source-of-truth producer detects shadow owner ambiguity"

ok "V2_single_source_of_truth_evidence passed"
