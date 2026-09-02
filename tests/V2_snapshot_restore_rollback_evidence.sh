#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

evidence_file="${tmp_dir}/recovery-evidence.json"
artifact_root="${tmp_dir}/artifacts/evaluations"

"${REPO_ROOT}/scripts/produce_v2_snapshot_restore_rollback_evidence.py" --output "${evidence_file}"
python3 - "${evidence_file}" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema_version"] == "v2-snapshot-restore-rollback-evidence.v0"
journey = data["journeys"]["snapshot-restore-rollback"]
assert journey["status"] == "pass"
assert journey["evidence"]["restored"]["state_restored"] is True
assert journey["evidence"]["restored"]["rollback_exact"] is True
assert journey["evidence"]["checkpoint"]["release"] == journey["evidence"]["restored"]["release"]
assert data["gates"]["p0-recovery-proven"]["status"] == "pass"
assert data["gates"]["p0-single-source-of-truth"]["status"] == "partial"
assert data["gates"]["p0-single-source-of-truth"]["evidence"]["authoritative"] is False
PY
ok "snapshot-restore-rollback producer writes pass-shaped recovery evidence"

set +e
"${REPO_ROOT}/scripts/run_v2_evaluation.py" \
  --artifact-root "${artifact_root}" \
  --evaluation-id recovery-produced \
  --evidence-file "${evidence_file}" >/tmp/agent-v2-recovery-eval.out 2>&1
eval_rc=$?
set -e
[[ "${eval_rc}" -eq 2 ]] || fail "recovery-only evidence must keep full evaluator in quarantine"
grep -q '^decision=quarantine$' /tmp/agent-v2-recovery-eval.out \
  || fail "recovery-only evidence must produce quarantine decision"
python3 - "${artifact_root}/recovery-produced/evaluation.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
journey = next(item for item in data["journeys"] if item["journey_id"] == "snapshot-restore-rollback")
assert journey["status"] == "pass"
assert any("bootstrap-doctor" in reason for reason in data["reasons"])
PY
ok "static evaluator consumes snapshot-restore-rollback evidence"

set +e
"${REPO_ROOT}/scripts/produce_v2_snapshot_restore_rollback_evidence.py" \
  --unsafe-skip-restore \
  --output "${tmp_dir}/skip-restore-evidence.json" >/tmp/agent-v2-recovery-skip.out 2>&1
skip_rc=$?
set -e
[[ "${skip_rc}" -ne 0 ]] || fail "skipping restore must fail evidence production"
python3 - "${tmp_dir}/skip-restore-evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
restored = data["journeys"]["snapshot-restore-rollback"]["evidence"]["restored"]
assert data["journeys"]["snapshot-restore-rollback"]["status"] == "fail"
assert restored["state_restored"] is False
assert data["gates"]["p0-recovery-proven"]["status"] == "fail"
PY
ok "snapshot-restore-rollback producer detects restore failure"

set +e
"${REPO_ROOT}/scripts/produce_v2_snapshot_restore_rollback_evidence.py" \
  --unsafe-corrupt-rollback \
  --output "${tmp_dir}/bad-rollback-evidence.json" >/tmp/agent-v2-recovery-rollback.out 2>&1
rollback_rc=$?
set -e
[[ "${rollback_rc}" -ne 0 ]] || fail "corrupt rollback must fail evidence production"
python3 - "${tmp_dir}/bad-rollback-evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
restored = data["journeys"]["snapshot-restore-rollback"]["evidence"]["restored"]
assert data["journeys"]["snapshot-restore-rollback"]["status"] == "fail"
assert restored["rollback_exact"] is False
assert data["gates"]["p0-recovery-proven"]["status"] == "fail"
PY
ok "snapshot-restore-rollback producer detects rollback mismatch"

ok "V2_snapshot_restore_rollback_evidence passed"
