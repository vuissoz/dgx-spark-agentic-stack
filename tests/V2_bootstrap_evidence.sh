#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

evidence_file="${tmp_dir}/bootstrap-evidence.json"
runtime_evidence_file="${tmp_dir}/bootstrap-runtime-evidence.json"
artifact_root="${tmp_dir}/artifacts/evaluations"
ready_doctor="${tmp_dir}/doctor-ready.sh"
failed_doctor="${tmp_dir}/doctor-failed.sh"

cat >"${ready_doctor}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "OK: doctor result: READY"
SH
chmod +x "${ready_doctor}"

cat >"${failed_doctor}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "WARN: doctor result: NOT READY"
exit 23
SH
chmod +x "${failed_doctor}"

"${REPO_ROOT}/scripts/produce_v2_bootstrap_evidence.py" --output "${evidence_file}"
python3 - "${evidence_file}" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema_version"] == "v2-bootstrap-evidence.v0"
assert "bootstrap-doctor" in data["journeys"]
assert data["journeys"]["bootstrap-doctor"]["status"] in {"partial", "pass"}
assert data["gates"]["p0-no-secret-or-data-leak"]["status"] == "pass"
assert data["gates"]["p0-no-direct-backend-or-docker-sock"]["status"] in {"partial", "pass"}
assert data["gates"]["p0-no-direct-backend-or-docker-sock"]["evidence"]["authoritative"] is False
assert data["gates"]["p0-recovery-proven"]["status"] == "partial"
assert data["gates"]["p0-recovery-proven"]["evidence"]["authoritative"] is False
assert data["gates"]["p0-audit-correlated"]["status"] == "partial"
assert data["gates"]["p0-audit-correlated"]["evidence"]["authoritative"] is False
assert data["runtime"]["doctor_executed"] is False
PY
ok "bootstrap evidence producer writes expected evidence shape"

"${REPO_ROOT}/scripts/produce_v2_bootstrap_evidence.py" \
  --run-doctor \
  --doctor-command "${ready_doctor}" \
  --output "${runtime_evidence_file}"
python3 - "${runtime_evidence_file}" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["runtime"]["doctor_executed"] is True
assert data["journeys"]["bootstrap-doctor"]["status"] == "pass"
audit = data["gates"]["p0-audit-correlated"]
assert audit["status"] == "pass"
assert audit["evidence"]["authoritative"] is True
assert audit["evidence"]["doctor_ready"] is True
forbidden = data["gates"]["p0-no-direct-backend-or-docker-sock"]
assert forbidden["status"] == "pass"
assert forbidden["evidence"]["authoritative"] is True
assert forbidden["evidence"]["doctor_ready"] is True
recovery = data["gates"]["p0-recovery-proven"]
assert recovery["status"] == "partial"
assert recovery["evidence"]["authoritative"] is False
PY
ok "bootstrap evidence producer promotes audit gate with runtime doctor evidence"

"${REPO_ROOT}/scripts/produce_v2_bootstrap_evidence.py" \
  --run-doctor \
  --doctor-command "${failed_doctor}" \
  --output "${tmp_dir}/bootstrap-failed-doctor-evidence.json"
python3 - "${tmp_dir}/bootstrap-failed-doctor-evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["journeys"]["bootstrap-doctor"]["status"] == "partial"
audit = data["gates"]["p0-audit-correlated"]
assert audit["status"] == "fail"
assert audit["evidence"]["authoritative"] is True
assert audit["evidence"]["doctor"]["exit_code"] == 23
forbidden = data["gates"]["p0-no-direct-backend-or-docker-sock"]
assert forbidden["status"] == "fail"
assert forbidden["evidence"]["authoritative"] is True
assert forbidden["evidence"]["doctor"]["exit_code"] == 23
PY
ok "bootstrap evidence producer records runtime doctor refusal"

set +e
"${REPO_ROOT}/scripts/run_v2_evaluation.py" \
  --artifact-root "${artifact_root}" \
  --evaluation-id bootstrap-produced \
  --evidence-file "${evidence_file}" >/tmp/agent-v2-bootstrap-eval.out 2>&1
eval_rc=$?
set -e
[[ "${eval_rc}" -eq 2 ]] || fail "partial bootstrap evidence must keep full evaluator in quarantine"
grep -q '^decision=quarantine$' /tmp/agent-v2-bootstrap-eval.out \
  || fail "partial bootstrap evidence must produce quarantine decision"
python3 - "${artifact_root}/bootstrap-produced/evaluation.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
journey = next(item for item in data["journeys"] if item["journey_id"] == "bootstrap-doctor")
assert journey["status"] == "partial"
assert any("context-isolation" in reason for reason in data["reasons"])
PY
ok "static evaluator consumes produced bootstrap evidence without fixtures"

bad_repo="${tmp_dir}/bad-repo"
mkdir -p "${bad_repo}"
set +e
"${REPO_ROOT}/scripts/produce_v2_bootstrap_evidence.py" \
  --repo-root "${bad_repo}" \
  --output "${tmp_dir}/bad-evidence.json" >/tmp/agent-v2-bootstrap-bad.out 2>&1
bad_rc=$?
set -e
[[ "${bad_rc}" -ne 0 ]] || fail "producer must fail when required repo evidence is absent"
python3 - "${tmp_dir}/bad-evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["journeys"]["bootstrap-doctor"]["status"] == "fail"
assert data["gates"]["p0-no-secret-or-data-leak"]["status"] == "fail"
PY
ok "bootstrap evidence producer records negative failure path"

ok "V2_bootstrap_evidence passed"
