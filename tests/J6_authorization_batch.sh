#!/usr/bin/env bash
# tests/J6_authorization_batch.sh — AuthorizationBatch validation (PLAN §12.4)
# Tests the batch document authorization system for RAG ACLs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_J_TESTS:-0}" == "1" ]]; then
  ok "J6 skipped because AGENTIC_SKIP_J_TESTS=1"
  exit 0
fi

assert_cmd python3

AUTH_SCRIPT="${REPO_ROOT}/deployments/optional/authorization_batch.py"
TEST_STORE="$(mktemp -d)/auth_batch.jsonl"
export AUTHORIZATION_BATCH_STORE="${TEST_STORE}"

ok "J6 test 1: authorization batch script exists and is executable"
[[ -f "${AUTH_SCRIPT}" ]] || fail "authorization_batch.py missing"
[[ -x "${AUTH_SCRIPT}" ]] || fail "authorization_batch.py not executable"

# --- Test: grant creation with validation ---
ok "J6 test 2: authorized grant is created and persisted"
grant_output="$(python3 "${AUTH_SCRIPT}" authorize \
    --files "/docs/report.pdf" \
    --directories "/workspace/ARTANY" \
    --projects ARTANY \
    --action index \
    --beneficiary "agent:codex" \
    --scope project \
    --expiration "2026-12-31T23:59:59Z" \
    --usage_limit 100 2>&1)"
grant_id="$(echo "${grant_output}" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['grant_id'])")"
[[ -n "${grant_id}" ]] || fail "authorization did not return grant_id: ${grant_output}"

# --- Test: list grants ---
ok "J6 test 3: grant appears in listing"
list_output="$(python3 "${AUTH_SCRIPT}" list)"
echo "${list_output}" | grep -q "index" \
  || fail "list should show granted action=index: ${list_output}"

# --- Test: JSON output ---
ok "J6 test 4: list with --json returns valid JSON array"
json_output="$(python3 "${AUTH_SCRIPT}" list --json)"
echo "${json_output}" | python3 -c "import json,sys; arr=json.loads(sys.stdin.read()); assert isinstance(arr,list)" \
  || fail "list --json should return a JSON array"

# --- Test: exclusion enforcement (no wildcard bypass) ---
ok "J6 test 5: secret patterns are excluded and cannot be authorized"
result="$(python3 "${AUTH_SCRIPT}" authorize \
    --files "*.secret" \
    --action index \
    --beneficiary "agent:codex" \
    --scope project 2>&1 || true)"
echo "${result}" | grep -qi "cannot authorize excluded pattern\|ERROR\|validation failed" \
  || fail "secret file patterns should be rejected by exclusion enforcement"

# --- Test: beneficiary format validation ---
ok "J6 test 6: invalid beneficiary formats are rejected"
result="$(python3 "${AUTH_SCRIPT}" authorize \
    --action read \
    --beneficiary "random_user" \
    --scope project 2>&1 || true)"
echo "${result}" | grep -qi "invalid beneficiary format\|ERROR\|validation failed" \
  || fail "non-standard beneficiary should be rejected"

# --- Test: action validation ---
ok "J6 test 7: invalid actions are rejected"
result="$(python3 "${AUTH_SCRIPT}" authorize \
    --action execute \
    --beneficiary "agent:codex" \
    --scope project 2>&1 || true)"
echo "${result}" | grep -qi "invalid action\|ERROR\|validation failed" \
  || fail "unsupported action should be rejected"

# --- Test: scope validation ---
ok "J6 test 8: invalid scopes are rejected"
result="$(python3 "${AUTH_SCRIPT}" authorize \
    --action read \
    --beneficiary "agent:codex" \
    --scope department 2>&1 || true)"
echo "${result}" | grep -qi "invalid scope\|ERROR\|validation failed" \
  || fail "unsupported scope should be rejected"

# --- Test: expiration/review date ordering ---
ok "J6 test 9: expiration must be after review date"
result="$(python3 "${AUTH_SCRIPT}" authorize \
    --action read \
    --beneficiary "agent:codex" \
    --scope global \
    --expiration "2025-01-01T00:00:00Z" \
    --review_date "2026-01-01T00:00:00Z" 2>&1 || true)"
echo "${result}" | grep -qi "expiration must be after\|ERROR\|validation failed" \
  || fail "earlier expiration than review date should be rejected"

# --- Test: dry-run preview ---
ok "J6 test 10: dry-run returns estimated documents, filters, exclusions"
dry_output="$(python3 "${AUTH_SCRIPT}" dry-run \
    --files "/docs/*.pdf" "/docs/*.txt" \
    --directories "/workspace/ARTANY" \
    --collections agentic_docs \
    --projects ARTANY SEGMENTATION-RTMRI \
    --labels "medical,runtime-data" \
    --action search \
    --beneficiary "group:analysts" \
    --scope project 2>&1)"

echo "${dry_output}" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
assert data.get('dry_run') == True
assert 'estimated_documents' in data
assert data['filters_applied']['files'] == ['/docs/*.pdf', '/docs/*.txt']
assert data['filters_applied']['collections'] == ['agentic_docs']
print('OK: dry-run returns complete preview with filters and exclusions')
" || fail "dry-run output invalid: ${dry_output}"

# --- Test: revocation ---
ok "J6 test 11: grant is revoked and status changes to 'revoked'"
python3 "${AUTH_SCRIPT}" revoke "${grant_id}" >/dev/null
list_json="$(python3 "${AUTH_SCRIPT}" list --json)"
status="$(echo "${list_json}" | python3 -c "import json,sys; grants=json.loads(sys.stdin.read()); print(grants[0].get('status'))")"
[[ "${status}" == "revoked" ]] || fail "grant should be revoked, got '${status}'"

# --- Test: usage_limit validation (non-negative) ---
ok "J6 test 12: negative usage_limit is rejected"
result="$(python3 "${AUTH_SCRIPT}" authorize \
    --action read \
    --beneficiary "agent:codex" \
    --scope project \
    --usage_limit -5 2>&1 || true)"
echo "${result}" | grep -qi "usage_limit must be\|ERROR\|validation failed" \
  || fail "negative usage_limit should be rejected"

# --- Test: multiple beneficiaries ---
ok "J6 test 13: multiple beneficiaries are supported"
multi_output="$(python3 "${AUTH_SCRIPT}" authorize \
    --files "/docs/shared.txt" \
    --action read \
    --beneficiary "user:alice" \
    --beneficiary "agent_class:data-scientist" \
    --scope organization 2>&1)"
multi_id="$(echo "${multi_output}" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['grant_id'])")"
[[ -n "${multi_id}" ]] || fail "multi-beneficiary grant should succeed: ${multi_output}"

# --- Test: auto-expiry of expired grants on list ---
ok "J6 test 14: expired grants are auto-transitioned to 'expired' status"
python3 "${AUTH_SCRIPT}" authorize \
    --action search \
    --beneficiary "agent:codex" \
    --scope project \
    --expiration "2020-01-01T00:00:00Z" >/dev/null 2>&1

python3 "${AUTH_SCRIPT}" list --json > /tmp/ab-list-expired.json 2>/dev/null
exp_status="$(python3 -c "
import json
grants = json.load(open('/tmp/ab-list-expired.json'))
for g in grants:
    if g.get('action') == 'search':
        print(g.get('status'))
        break
")" || exp_status="missing"
[[ "${exp_status}" == "expired" ]] \
  || fail "granted grant with past expiration should be auto-expired, got '${exp_status}'"

# --- Test: admin_all_matching flag ---
ok "J6 test 15: --yes-all flag is accepted and recorded in grant store"
python3 "${AUTH_SCRIPT}" authorize \
    --collections agentic_docs \
    --action index \
    --beneficiary "agent:codex" \
    --scope project \
    --yes-all >/dev/null 2>&1

admin_flag="$(python3 -c "
import json, os
store = os.environ.get('AUTHORIZATION_BATCH_STORE', '${AUTHORIZATION_BATCH_STORE}')
grants = []
with open(store) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: grants.append(json.loads(line))
        except: pass
for g in reversed(grants):
    if 'agentic_docs' in g.get('collections', []):
        val = g.get('admin_all_matching')
        print(str(val))
        break
else:
    print('NOT_FOUND')
" 2>/dev/null)" || admin_flag="ERROR"
[[ "${admin_flag}" == "True" ]] \
  || fail "--yes-all should set admin_all_matching to True, got '${admin_flag}'"


# --- Test: explicit refusal patterns are excluded ---
ok "J6 test 16: regulated data patterns (.env, .ssh/*, *.key) are excluded"
for pattern in ".env" ".ssh/id_rsa" "*.key" "*.pem" "passwords.txt"; do
  result="$(python3 "${AUTH_SCRIPT}" authorize \
      --files "${pattern}" \
      --action read \
      --beneficiary "agent:codex" \
      --scope project 2>&1 || true)"
  echo "${result}" | grep -qi "cannot authorize excluded pattern\|ERROR\|validation failed" \
    || fail "pattern '${pattern}' should be blocked by exclusion enforcement"
done

# Cleanup
rm -rf /tmp/ab-*.json /tmp/ab-list-expired.json 2>/dev/null || true

ok "J6_authorization_batch passed"

# --- Test: explicit refusal patterns are excluded ---
ok "J6 test 16: regulated data patterns (.env, .ssh/*, *.key) are excluded"
for pattern in ".env" ".ssh/id_rsa" "*.key" "*.pem" "passwords.txt"; do
  result="$(python3 "${AUTH_SCRIPT}" authorize \
      --files "${pattern}" \
      --action read \
      --beneficiary "agent:codex" \
      --scope project 2>&1 || true)"
  echo "${result}" | grep -qi "cannot authorize excluded pattern\|ERROR\|validation failed" \
    || fail "pattern '${pattern}' should be blocked by exclusion enforcement"
done

# Cleanup
rm -rf /tmp/ab-*.json /tmp/ab-list-expired.json 2>/dev/null || true

ok "J6_authorization_batch passed"
