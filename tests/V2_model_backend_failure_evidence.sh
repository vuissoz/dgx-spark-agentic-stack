#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

evidence_file="${tmp_dir}/model-evidence.json"
fallback_evidence_file="${tmp_dir}/model-fallback-evidence.json"
artifact_root="${tmp_dir}/artifacts/evaluations"

"${REPO_ROOT}/scripts/produce_v2_model_backend_failure_evidence.py" --output "${evidence_file}"
python3 - "${evidence_file}" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema_version"] == "v2-model-backend-failure-evidence.v0"
journey = data["journeys"]["model-backend-failure"]
assert journey["status"] == "pass"
assert journey["evidence"]["direct_backend_probe"]["status"] == "refused"
scenario = journey["evidence"]["broker_failure_scenario"]
assert scenario["status"] == "actionable_refusal"
assert scenario["primary_backend"]["status"] == "unavailable"
assert scenario["actionable"] is True
assert data["gates"]["p0-no-direct-backend-or-docker-sock"]["status"] == "pass"
assert data["gates"]["p0-audit-correlated"]["status"] == "partial"
assert data["gates"]["p0-audit-correlated"]["evidence"]["authoritative"] is False
PY
ok "model-backend producer writes actionable-refusal evidence"

"${REPO_ROOT}/scripts/produce_v2_model_backend_failure_evidence.py" \
  --fallback-enabled \
  --output "${fallback_evidence_file}"
python3 - "${fallback_evidence_file}" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
scenario = data["journeys"]["model-backend-failure"]["evidence"]["broker_failure_scenario"]
assert scenario["status"] == "explicit_fallback"
assert scenario["fallback_backend"]["status"] == "selected"
assert data["journeys"]["model-backend-failure"]["status"] == "pass"
PY
ok "model-backend producer writes explicit-fallback evidence"

set +e
"${REPO_ROOT}/scripts/run_v2_evaluation.py" \
  --artifact-root "${artifact_root}" \
  --evaluation-id model-produced \
  --evidence-file "${evidence_file}" >/tmp/agent-v2-model-eval.out 2>&1
eval_rc=$?
set -e
[[ "${eval_rc}" -eq 2 ]] || fail "model-only evidence must keep full evaluator in quarantine"
grep -q '^decision=quarantine$' /tmp/agent-v2-model-eval.out \
  || fail "model-only evidence must produce quarantine decision"
python3 - "${artifact_root}/model-produced/evaluation.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
journey = next(item for item in data["journeys"] if item["journey_id"] == "model-backend-failure")
assert journey["status"] == "pass"
assert any("bootstrap-doctor" in reason for reason in data["reasons"])
PY
ok "static evaluator consumes model-backend-failure evidence"

set +e
"${REPO_ROOT}/scripts/produce_v2_model_backend_failure_evidence.py" \
  --unsafe-allow-direct-backend \
  --output "${tmp_dir}/direct-access-evidence.json" >/tmp/agent-v2-model-direct.out 2>&1
direct_rc=$?
set -e
[[ "${direct_rc}" -ne 0 ]] || fail "unsafe direct backend access must fail evidence production"
python3 - "${tmp_dir}/direct-access-evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["journeys"]["model-backend-failure"]["status"] == "fail"
assert data["gates"]["p0-no-direct-backend-or-docker-sock"]["status"] == "fail"
assert data["journeys"]["model-backend-failure"]["evidence"]["direct_backend_probe"]["status"] == "allowed"
PY
ok "model-backend producer detects direct backend access"

set +e
"${REPO_ROOT}/scripts/produce_v2_model_backend_failure_evidence.py" \
  --unsafe-silent-success \
  --output "${tmp_dir}/silent-success-evidence.json" >/tmp/agent-v2-model-silent.out 2>&1
silent_rc=$?
set -e
[[ "${silent_rc}" -ne 0 ]] || fail "silent success over backend failure must fail evidence production"
python3 - "${tmp_dir}/silent-success-evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
scenario = data["journeys"]["model-backend-failure"]["evidence"]["broker_failure_scenario"]
assert data["journeys"]["model-backend-failure"]["status"] == "fail"
assert scenario["status"] == "silent_success"
assert scenario["actionable"] is False
PY
ok "model-backend producer rejects silent success over failed backend"

ok "V2_model_backend_failure_evidence passed"
