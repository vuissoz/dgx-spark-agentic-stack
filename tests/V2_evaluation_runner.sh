#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

evidence_file="${tmp_dir}/evidence.json"
artifact_root="${tmp_dir}/artifacts/evaluations"
cat >"${evidence_file}" <<'JSON'
{
  "gates": {
    "p0-no-secret-or-data-leak": {"status": "pass", "evidence": "static negative fixture"},
    "p0-single-source-of-truth": {"status": "pass", "evidence": "architecture spec checked"},
    "p0-recovery-proven": {"status": "pass", "evidence": "recovery artifact contract checked"},
    "p0-no-direct-backend-or-docker-sock": {"status": "pass", "evidence": "static forbidden pattern fixture"},
    "p0-audit-correlated": {"status": "pass", "evidence": "audit field fixture"}
  },
  "journeys": {
    "bootstrap-doctor": {"status": "pass", "evidence": "fixture bootstrap evidence"},
    "codex-repo-change": {"status": "pass", "evidence": "fixture codex evidence"},
    "context-isolation": {"status": "pass", "evidence": "fixture isolation evidence"},
    "model-backend-failure": {"status": "pass", "evidence": "fixture model failure evidence"},
    "snapshot-restore-rollback": {"status": "pass", "evidence": "fixture rollback evidence"}
  },
  "runtime": {
    "api_token": "must not appear",
    "note": "fixture runtime"
  }
}
JSON

"${REPO_ROOT}/scripts/run_v2_evaluation.py" \
  --artifact-root "${artifact_root}" \
  --evaluation-id passing-fixture \
  --evidence-file "${evidence_file}" >/tmp/agent-v2-eval-pass.out

eval_dir="${artifact_root}/passing-fixture"
for artifact in evaluation.json manifest.json gates.json runtime.json engineering.json pareto.json recovery.json report.md; do
  [[ -s "${eval_dir}/${artifact}" ]] || fail "missing evaluation artifact: ${artifact}"
done
grep -q '^decision=pareto$' /tmp/agent-v2-eval-pass.out \
  || fail "passing evidence must produce pareto decision"
grep -Rq '\[REDACTED\]' "${eval_dir}" \
  || fail "sensitive evidence keys must be redacted in artifacts"
! grep -Rq 'must not appear' "${eval_dir}" \
  || fail "secret-like evidence value leaked into artifacts"
python3 - "${eval_dir}/evaluation.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema_version"].startswith("v2-")
assert data["status"] == "pass"
assert data["decision"] == "pareto"
assert data["metrics"]["journeys_total"] == 5
assert data["metrics"]["journeys_passed"] == 5
PY
ok "v2 evaluation runner writes passing artifact bundle"

set +e
"${REPO_ROOT}/scripts/run_v2_evaluation.py" \
  --artifact-root "${artifact_root}" \
  --evaluation-id missing-p0-fixture >/tmp/agent-v2-eval-missing.out 2>&1
missing_rc=$?
set -e
[[ "${missing_rc}" -eq 2 ]] || fail "missing P0 evidence must exit 2"
grep -q '^decision=quarantine$' /tmp/agent-v2-eval-missing.out \
  || fail "missing P0 evidence must quarantine the candidate"
[[ -s "${artifact_root}/missing-p0-fixture/evaluation.json" ]] \
  || fail "missing P0 evidence path must still write evaluation artifacts"
ok "v2 evaluation runner fails closed on missing P0 evidence"

bad_repo="${tmp_dir}/bad-repo"
mkdir -p "${bad_repo}/evaluation/spec" \
  "${bad_repo}/evaluation/corpora/visible/v2-walking-skeleton-v0" \
  "${bad_repo}/evaluation/tasks/engineering/v2-changeability-v0"
printf '{bad json' >"${bad_repo}/evaluation/spec/capabilities.yaml"
for spec in architecture metrics promotion recovery retention; do
  printf '{}' >"${bad_repo}/evaluation/spec/${spec}.yaml"
done
printf '{}' >"${bad_repo}/evaluation/corpora/visible/v2-walking-skeleton-v0/manifest.yaml"
printf '{}' >"${bad_repo}/evaluation/tasks/engineering/v2-changeability-v0/manifest.yaml"

set +e
"${REPO_ROOT}/scripts/run_v2_evaluation.py" \
  --repo-root "${bad_repo}" \
  --artifact-root "${artifact_root}" \
  --evaluation-id malformed-fixture >/tmp/agent-v2-eval-bad.out 2>&1
bad_rc=$?
set -e
[[ "${bad_rc}" -ne 0 ]] || fail "malformed specs must fail"
grep -q 'must remain JSON-subset YAML' /tmp/agent-v2-eval-bad.out \
  || fail "malformed spec failure must be actionable"
ok "v2 evaluation runner rejects malformed specs"

ok "V2_evaluation_runner passed"
