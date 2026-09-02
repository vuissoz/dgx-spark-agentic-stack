#!/usr/bin/env bash
# tests/J13_external_access_broker.sh — Validate ExternalAccessBroker + SecretStore (§10.2, §10.1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_cmd python3

ok "J13 test 1: ExternalAccessBroker module imports and satisfies contract"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.external_access_broker import (
    ExternalAccessBroker, SecretStore
)
assert hasattr(ExternalAccessBroker, 'rotate_credentials')
assert hasattr(ExternalAccessBroker, 'revoke_credentials')
assert hasattr(ExternalAccessBroker, 'health_check')
assert hasattr(SecretStore, 'store')
assert hasattr(SecretStore, 'get')
assert hasattr(SecretStore, 'rotate')
print('PASS')
" || fail "J13 test 1: contract violations"

ok "J13 test 2: rotate_credentials creates credential with token_id and metadata"
python3 -c "
import sys; asyncio = __import__('asyncio'); sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.external_access_broker import ExternalAccessBroker
broker = ExternalAccessBroker()
result = asyncio.run(broker.rotate_credentials('github', 'github.contents.read', user_id='alice'))
assert result['token_id'].startswith('cred-'), f'Bad token_id: {result[\"token_id\"]}'
assert result['service'] == 'github'
assert result['scope'] == 'github.contents.read'
assert result['user_id'] == 'alice'
print('PASS')
" || fail "J13 test 2: rotation failed"

ok "J13 test 3: rotate_credentials rejects unknown services"
python3 -c "
import sys; asyncio = __import__('asyncio'); sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.external_access_broker import ExternalAccessBroker
broker = ExternalAccessBroker()
result = asyncio.run(broker.rotate_credentials('unknown', 'test'))
assert 'error' in result, f'Expected error: {result}'
print('PASS')
" || fail "J13 test 3: unknown service accepted"

ok "J13 test 4: revoke_credentials marks credential as revoked"
python3 -c "
import sys; asyncio = __import__('asyncio'); sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.external_access_broker import ExternalAccessBroker
broker = ExternalAccessBroker()
result = asyncio.run(broker.rotate_credentials('github', 'github.contents.read', user_id='bob'))
tid = result['token_id']
revoked = asyncio.run(broker.revoke_credentials(tid))
assert revoked == True, 'Expected revoke to succeed'
print('PASS')
" || fail "J13 test 4: revocation failed"

ok "J13 test 5: health_check returns True for configured services"
python3 -c "
import sys; asyncio = __import__('asyncio'); sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.external_access_broker import ExternalAccessBroker
broker = ExternalAccessBroker()
result = asyncio.run(broker.health_check())
assert result == True, f'Expected health=True: {result}'
print('PASS')
" || fail "J13 test 5: health check failed"

ok "J13 test 6: SecretStore stores and retrieves metadata (never value)"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.external_access_broker import SecretStore
store = SecretStore()
sid = store.store('test-key', 'secret-value', scope='project:test')
meta = store.get(sid)
assert meta is not None
assert meta['name'] == 'test-key'
assert meta['scope'] == 'project:test'
assert 'value' not in str(meta), f'Secret value leaked: {meta}'
print('PASS')
" || fail "J13 test 6: SecretStore store/get failed"

ok "J13 test 7: SecretStore rotate returns new ID with incremented rotation count"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.external_access_broker import SecretStore
store = SecretStore()
sid = store.store('rotate-key', 'value', scope='global')
new_id = store.rotate(sid)
assert new_id is not None and new_id != sid, f'Expected new ID: {new_id}'
old_meta = store.get(sid)
assert old_meta is None, 'Old secret should be gone after rotate'
print('PASS')
" || fail "J13 test 7: SecretStore rotation failed"

ok "J13 test 8: Audit log captures all actions"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.external_access_broker import SecretStore
store = SecretStore()
sid = store.store('audit-key', 'value')
meta = store.get(sid)
log = store.audit_log()
assert len(log) >= 2, f'Expected at least 2 log entries: {len(log)}'
actions = [e['action'] for e in log]
assert 'store' in actions and 'get' in actions
print('PASS')
" || fail "J13 test 8: audit log missing entries"

echo ""
echo "=== J13_external_access_broker passed ==="
