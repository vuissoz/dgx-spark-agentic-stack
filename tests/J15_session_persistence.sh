#!/usr/bin/env bash
# tests/J15_session_persistence.sh — §5.3 Session persistence: hot/cold/native recovery validation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_cmd python3

TMP_STATE="$(mktemp -d)"
trap 'rm -rf "$TMP_STATE"' EXIT

# Test 1: SessionState serializes and deserializes correctly
ok "J15 test 1: SessionState serialization roundtrip"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.session_persistence import SessionState

state = SessionState(
    session_id='sess-test-001',
    user_id='alice',
    project='ARTANY',
    harness='codex',
    sandbox_id='sandbox-abc123',
    process_ids=['proc-001', 'proc-002'],
    checkpoint_data={'memory': {'key': 'value'}},
)

# Serialize to dict and back
d = state.to_dict()
restored = SessionState.from_dict(d)

assert restored.session_id == state.session_id
assert restored.user_id == state.user_id
assert restored.project == state.project
assert restored.harness == state.harness
assert restored.sandbox_id == state.sandbox_id
assert restored.process_ids == state.process_ids
assert restored.checkpoint_data == state.checkpoint_data
print('PASS')
" || fail "J15 test 1: SessionState roundtrip failed"

# Test 2: SessionPersistenceManager saves/loads state to disk
ok "J15 test 2: SessionPersistenceManager persist and load"
python3 -c "
import sys, os; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.session_persistence import SessionState, SessionPersistenceManager

mgr = SessionPersistenceManager(state_dir='${TMP_STATE}')

# Save state
state = SessionState(
    session_id='sess-test-002',
    user_id='bob',
    project='SEGMENTATION',
    harness='hermes',
    sandbox_id='sandbox-def456',
)
mgr.save_session_state(state)

# Verify file exists on disk
import json
expected_file = os.path.join('${TMP_STATE}', 'bob', 'sess-test-002.json')
assert os.path.exists(expected_file), f'Session file not created at {expected_file}'

# Load state back
loaded = mgr.load_session_state('bob', 'sess-test-002')
assert loaded is not None, 'Expected loaded session'
assert loaded.session_id == state.session_id
assert loaded.user_id == 'bob'
assert loaded.project == 'SEGMENTATION'
print('PASS')
" || fail "J15 test 2: Persistence manager save/load failed"

# Test 3: Hot recovery preserves active sandbox/processes
ok "J15 test 3: hot_recovery validates live sandbox detection"
python3 -c "
import sys, asyncio; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.session_persistence import SessionState, SessionPersistenceManager

mgr = SessionPersistenceManager(state_dir='${TMP_STATE}')

state = SessionState(
    session_id='sess-hot-001',
    user_id='charlie',
    harness='codex',
    sandbox_id='sandbox-live-001',
    process_ids=['proc-abc'],
)

# Save then attempt hot recovery
mgr.save_session_state(state)
result = asyncio.run(mgr.recover_session_hot(state))
assert result.status == 'success', f'Expected success for hot recovery: {result.details}'
assert result.session_id == state.session_id
print('PASS')
" || fail "J15 test 3: Hot recovery failed"

# Test 4: Cold recovery validates missing state handling
ok "J15 test 4: cold_recovery handles missing state gracefully"
python3 -c "
import sys, asyncio; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.session_persistence import SessionPersistenceManager

mgr = SessionPersistenceManager(state_dir='${TMP_STATE}')

# Attempt recovery of non-existent session
result = asyncio.run(mgr.recover_session_cold('unknown_user', 'nonexistent'))
assert result.status == 'failed', f'Expected failed for missing state: {result}'
assert 'No saved state' in result.details, f'Expected details about missing state: {result.details}'
print('PASS')
" || fail "J15 test 4: Cold recovery error handling failed"

# Test 5: Delete session removes persisted file
ok "J15 test 5: delete_session_state removes persisted data"
python3 -c "
import sys, os; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.session_persistence import SessionState, SessionPersistenceManager

mgr = SessionPersistenceManager(state_dir='${TMP_STATE}')

state = SessionState(session_id='sess-del-001', user_id='dave', harness='openhands')
mgr.save_session_state(state)
assert os.path.exists(os.path.join('${TMP_STATE}', 'dave', 'sess-del-001.json'))

deleted = mgr.delete_session_state('dave', 'sess-del-001')
assert deleted == True, 'Expected deletion to succeed'
assert not os.path.exists(os.path.join('${TMP_STATE}', 'dave', 'sess-del-001.json')), 'File should be removed'
print('PASS')
" || fail "J15 test 5: Delete session failed"

# Test 6: List user sessions discovers persisted entries
ok "J15 test 6: list_user_sessions discovers all saved sessions"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.session_persistence import SessionState, SessionPersistenceManager

mgr = SessionPersistenceManager(state_dir='${TMP_STATE}')

# Save multiple sessions for the same user
for i in range(3):
    state = SessionState(
        session_id=f'sess-list-{i}',
        user_id='eve',
        harness='claude',
        project=f'PROJECT-{i}',
    )
    mgr.save_session_state(state)

sessions = mgr.list_user_sessions('eve')
assert len(sessions) == 3, f'Expected 3 sessions for eve: got {len(sessions)}'
# Verify session IDs are present
ids = [s['session_id'] for s in sessions]
for i in range(3):
    assert f'sess-list-{i}' in ids, f'Missing sess-list-{i} from list'
print('PASS')
" || fail "J15 test 6: List user sessions failed"

# Test 7: Session persistence integrates with ControlPlaneState.status()
ok "J15 test 7: integration with control plane status shows active_sessions"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.api import get_control_state

state = get_control_state()
status = state.status()
assert 'active_sessions' in status, f'Missing active_sessions from status: {list(status.keys())}'
# Should be 0 since no sessions created yet via API
assert isinstance(status['active_sessions'], int), f'Expected int for active_sessions count'
print(f'PASS (status includes active_sessions={status[\"active_sessions\"]})')
" || fail "J15 test 7: Control plane status integration failed"

# Test 8: Recovery log captures all attempts (audit trail)
ok "J15 test 8: recovery_audit_log tracks hot/cold attempt history"
python3 -c "
import sys, asyncio; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.session_persistence import SessionState, SessionPersistenceManager

mgr = SessionPersistenceManager(state_dir='${TMP_STATE}')

# Save a session for later hot recovery
state = SessionState(session_id='sess-audit-001', user_id='frank', harness='codex')
mgr.save_session_state(state)

# Perform hot recovery (should log)
r1 = asyncio.run(mgr.recover_session_hot(state))

# Attempt cold recovery of missing session (should also log)
r2 = asyncio.run(mgr.recover_session_cold('nobody', 'missing'))

log = mgr._recovery_log
assert len(log) >= 2, f'Expected at least 2 recovery records: {len(log)}'

actions = [l.status for l in log]
assert 'success' in actions or 'failed' in actions, f'Expected recorded statuses: {actions}'

print(f'PASS (recovery_log has {len(log)} entries)')
" || fail "J15 test 8: Recovery audit trail failed"

echo ""
echo "=== J15_session_persistence passed ==="
