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
artifact_root="${tmp_dir}/artifacts/evaluations"

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
PY
ok "single-source-of-truth producer writes runtime-backed ownership evidence"

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
