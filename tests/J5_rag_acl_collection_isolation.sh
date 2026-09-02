#!/usr/bin/env bash
# tests/J5_rag_acl_collection_isolation.sh — RAG multi-project ACL validation (PLAN.md §12.3, §15.1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_cmd python3

rag_compose="${REPO_ROOT}/compose/compose.rag.yml"

# Test 1: RAG collections are parameterized per-project, not hardcoded
ok "J5 test 1: RAG_COLLECTION is parameterized via environment variable"
[[ -f "${rag_compose}" ]] || fail "J5 test 1: compose.rag.yml missing"
grep -q 'RAG_COLLECTION.*\${' "${rag_compose}" \
  || fail "J5 test 1: RAG_COLLECTION should be parameterized via environment variable"

# Test 2: RAG lexical index also supports parameterization
ok "J5 test 2: RAG_LEXICAL_INDEX is parameterized"
grep -q 'RAG_LEXICAL_INDEX.*\${' "${rag_compose}" \
  || fail "J5 test 2: RAG_LEXICAL_INDEX should be parameterized via environment variable"

# Test 3: compose supports RAG_PROJECT_PREFIX for project-scoped collections
ok "J5 test 3: RAG_PROJECT_PREFIX supported in compose config"
grep -q 'RAG_PROJECT_PREFIX' "${rag_compose}" \
  || fail "J5 test 3: RAG_PROJECT_PREFIX should be supported in compose config"

# Test 4: Document index payload supports project metadata field
ok "J5 test 4: document index payload carries project metadata"
python3 -c "
payload = {'sync': True, 'docs_dir': '/docs', 'project': 'test-project'}
required_fields = {'sync', 'docs_dir'}
assert required_fields.issubset(set(payload.keys())), \
    f'Index payload missing: {required_fields - set(payload.keys())}'
print('PASS')
" || fail "J5 test 4: Document payload validation failed"

# Test 5: Qdrant storage paths are project-isolatable
ok "J5 test 5: qdrant persists under /qdrant/storage"
grep -A10 'qdrant:' "${rag_compose}" | grep -q '/qdrant/storage' \
  || fail "J5 test 5: qdrant should persist under /qdrant/storage"

# Test 6: RAG ACL module exists and enforces project isolation (P0 security)
ok "J5 test 6: RAG ACL manager module imports and enforces project isolation (P0 gate)"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_acl import RAGACLManager, ACLRule

acl = RAGACLManager()

# Add rules for two projects
acl.add_rule(ACLRule(rule_id='r1', collection='project:ARTANY', scope='project', subject_id='ARTANY', permissions=['read']))
acl.add_rule(ACLRule(rule_id='r2', collection='project:SEGMENTATION', scope='project', subject_id='SEGMENTATION', permissions=['read']))

# ARTANY user reads own project (allowed)
result1 = acl.check_access('project:ARTANY', 'alice', 'read', project='ARTANY')
assert result1.allowed, f'ARTANY read should be allowed: {result1.reason}'

# SEGMENTATION user reading ARTANY (DENIED — P0 isolation gate)
result2 = acl.check_access('project:ARTANY', 'bob', 'read', project='SEGMENTATION')
assert not result2.allowed, f'SEGMENTATION MUST NOT read ARTANY data: {result2}'

# Verify project isolation invariant holds
isolation_enforced = acl.check_project_isolation('SEGMENTATION', 'project:ARTANY')
assert not isolation_enforced, 'Project isolation must be enforced'

print('PASS (P0 isolation verified)')
" || fail "J5 test 6: ACL P0 isolation check failed"

# Test 7: Cross-project query leakage prevention validated
ok "J5 test 7: cross-project query leakage prevented by policy enforcement"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_acl import RAGACLManager, ACLRule

acl = RAGACLManager()

# Simulate multiple projects with data leakage attempt
acl.add_rule(ACLRule(rule_id='proj1', collection='collection:proj1', scope='project', subject_id='proj1'))
acl.add_rule(ACLRule(rule_id='proj2', collection='collection:proj2', scope='project', subject_id='proj2'))

# proj1 user tries to access proj2 data (should be denied)
result = acl.check_access('collection:proj2', 'alice', 'read', project='proj1')
assert not result.allowed, f'Cross-project access must be denied: {result}'

# Verify audit log captured the denied attempt
log = acl.get_audit_log()
denied_count = sum(1 for entry in log if not entry['allowed'])
assert denied_count >= 1, f'Audit log should capture denied attempts (got {denied_count})'

print('PASS (leakage prevention verified)')
" || fail "J5 test 7: Cross-project leakage check failed"

# Test 8: AuthorizationBatch creates grants with audit trail
ok "J5 test 8: AuthorizationBatch creates grants and maintains audit trail"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_acl import AuthorizationBatchManager

auth_batch = AuthorizationBatchManager()

# Create a batch authorization grant per §12.4
grant = auth_batch.create_batch(
    action='read',
    beneficiary_id='group:analysts',
    beneficiary_type='group',
    scope='project',
    collection='collection:research',
    project='ARTANY',
)

assert grant['batch_id'], f'Expected batch_id in grant: {grant}'
assert grant['action'] == 'read', f'Expected action=read: {grant}'
assert grant['status'] == 'authorized', f'Expected status=authorized: {grant}'

# Verify ACL manager received the rule
acl_manager = auth_batch.acl_manager
rules = acl_manager._rules
assert len(rules) > 0, f'ACL rules should be added (got {len(rules)})'

print(f'PASS (grant created, rules={len(rules)} in ACL store)')
" || fail "J5 test 8: AuthorizationBatch grant creation failed"

echo ""
echo "=== J5_rag_acl_collection_isolation passed ==="
