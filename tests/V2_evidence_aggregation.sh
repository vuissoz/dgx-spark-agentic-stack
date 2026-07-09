#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

combined_file="${tmp_dir}/combined-evidence.json"
artifact_root="${tmp_dir}/artifacts/evaluations"

"${REPO_ROOT}/scripts/aggregate_v2_evidence.py" --output "${combined_file}"
python3 - "${combined_file}" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema_version"] == "v2-combined-evidence.v0"
assert data["aggregation"]["status"] == "pass"
for journey in ["bootstrap-doctor", "context-isolation", "model-backend-failure", "snapshot-restore-rollback"]:
    assert journey in data["journeys"], journey
assert data["journeys"]["bootstrap-doctor"]["status"] in {"partial", "pass"}
assert data["journeys"]["context-isolation"]["status"] == "pass"
assert data["journeys"]["model-backend-failure"]["status"] == "pass"
assert data["journeys"]["snapshot-restore-rollback"]["status"] == "pass"
assert len(data["runtime"]["producers"]) == 4
PY
ok "v2 evidence aggregator writes combined walking-skeleton evidence"

set +e
"${REPO_ROOT}/scripts/run_v2_evaluation.py" \
  --artifact-root "${artifact_root}" \
  --evaluation-id combined-static \
  --evidence-file "${combined_file}" >/tmp/agent-v2-combined-eval.out 2>&1
eval_rc=$?
set -e
[[ "${eval_rc}" -eq 2 ]] || fail "combined static evidence must still quarantine while partial P0 gates remain"
grep -q '^decision=quarantine$' /tmp/agent-v2-combined-eval.out \
  || fail "combined static evidence must produce quarantine decision"
python3 - "${artifact_root}/combined-static/evaluation.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
journeys = {item["journey_id"]: item["status"] for item in data["journeys"]}
assert journeys["context-isolation"] == "pass"
assert journeys["model-backend-failure"] == "pass"
assert journeys["snapshot-restore-rollback"] == "pass"
assert journeys["bootstrap-doctor"] in {"partial", "pass"}
assert any("p0-single-source-of-truth" in reason for reason in data["reasons"])
PY
ok "static evaluator consumes combined evidence file"

input_a="${tmp_dir}/input-a.json"
input_b="${tmp_dir}/input-b.json"
cat >"${input_a}" <<'JSON'
{
  "schema_version": "v2-test-evidence.v0",
  "producer": "test-a",
  "journeys": {
    "context-isolation": {
      "status": "pass",
      "evidence": {"value": "a"}
    }
  }
}
JSON
cat >"${input_b}" <<'JSON'
{
  "schema_version": "v2-test-evidence.v0",
  "producer": "test-b",
  "journeys": {
    "context-isolation": {
      "status": "fail",
      "evidence": {"value": "b"}
    }
  }
}
JSON

set +e
"${REPO_ROOT}/scripts/aggregate_v2_evidence.py" \
  --no-default-producers \
  --input "${input_a}" \
  --input "${input_b}" \
  --output "${tmp_dir}/conflict.json" >/tmp/agent-v2-aggregate-conflict.out 2>&1
conflict_rc=$?
set -e
[[ "${conflict_rc}" -ne 0 ]] || fail "conflicting evidence must fail aggregation"
python3 - "${tmp_dir}/conflict.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["aggregation"]["status"] == "fail"
assert any("conflicting journeys.context-isolation" in item for item in data["aggregation"]["conflicts"])
PY
ok "v2 evidence aggregator rejects conflicting evidence"

set +e
"${REPO_ROOT}/scripts/aggregate_v2_evidence.py" \
  --no-default-producers \
  --producer scripts/does-not-exist.py \
  --output "${tmp_dir}/failed-producer.json" >/tmp/agent-v2-aggregate-failed.out 2>&1
failed_rc=$?
set -e
[[ "${failed_rc}" -ne 0 ]] || fail "failing producer must fail aggregation"
python3 - "${tmp_dir}/failed-producer.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["aggregation"]["status"] == "fail"
assert any("producer failed" in item for item in data["aggregation"]["conflicts"])
PY
ok "v2 evidence aggregator records failing producers"

ok "V2_evidence_aggregation passed"
