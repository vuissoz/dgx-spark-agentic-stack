#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

evidence_file="${tmp_dir}/context-evidence.json"
artifact_root="${tmp_dir}/artifacts/evaluations"

"${REPO_ROOT}/scripts/produce_v2_context_isolation_evidence.py" --output "${evidence_file}"
python3 - "${evidence_file}" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema_version"] == "v2-context-isolation-evidence.v0"
journey = data["journeys"]["context-isolation"]
assert journey["status"] == "pass"
checks = journey["evidence"]["positive_same_context_checks"]
assert len(checks) == 2
assert all(item["status"] == "read" for item in checks)
assert journey["evidence"]["negative_cross_context_check"]["status"] == "refused"
assert data["gates"]["p0-no-secret-or-data-leak"]["status"] == "pass"
assert data["gates"]["p0-single-source-of-truth"]["status"] == "partial"
assert data["gates"]["p0-single-source-of-truth"]["evidence"]["authoritative"] is False
PY
ok "context-isolation producer writes pass-shaped local policy evidence"

set +e
"${REPO_ROOT}/scripts/run_v2_evaluation.py" \
  --artifact-root "${artifact_root}" \
  --evaluation-id context-produced \
  --evidence-file "${evidence_file}" >/tmp/agent-v2-context-eval.out 2>&1
eval_rc=$?
set -e
[[ "${eval_rc}" -eq 2 ]] || fail "context-only evidence must keep full evaluator in quarantine"
grep -q '^decision=quarantine$' /tmp/agent-v2-context-eval.out \
  || fail "context-only evidence must produce quarantine decision"
python3 - "${artifact_root}/context-produced/evaluation.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
journey = next(item for item in data["journeys"] if item["journey_id"] == "context-isolation")
assert journey["status"] == "pass"
assert any("bootstrap-doctor" in reason for reason in data["reasons"])
PY
ok "static evaluator consumes context-isolation evidence"

set +e
"${REPO_ROOT}/scripts/produce_v2_context_isolation_evidence.py" \
  --unsafe-allow-cross-context \
  --output "${tmp_dir}/leaky-evidence.json" >/tmp/agent-v2-context-leaky.out 2>&1
leaky_rc=$?
set -e
[[ "${leaky_rc}" -ne 0 ]] || fail "unsafe cross-context mode must fail evidence production"
python3 - "${tmp_dir}/leaky-evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["journeys"]["context-isolation"]["status"] == "fail"
assert data["gates"]["p0-no-secret-or-data-leak"]["status"] == "fail"
assert data["journeys"]["context-isolation"]["evidence"]["negative_cross_context_check"]["status"] == "read"
PY
ok "context-isolation producer detects simulated leakage"

ok "V2_context_isolation_evidence passed"
