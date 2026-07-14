#!/usr/bin/env bash
# tests/J14_auth_workspace.sh — Validate auth middleware + workspace management (§5, §M4)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_cmd python3

# Test 1: Auth middleware imports and creates sessions
ok "J14 test 1: AuthMiddleware module imports and creates sessions"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.auth import AuthMiddleware, RoleChecker

auth = AuthMiddleware()
session = auth.create_session('alice', roles=['admin'], project='ARTANY', ttl_seconds=3600)
assert session is not None
assert session.user_id == 'alice'
assert session.project == 'ARTANY'
print('PASS')
" || fail "J14 test 1: AuthMiddleware import failed"

# Test 2: Session validation works
ok "J14 test 2: validate_session returns UserSession or None"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.auth import AuthMiddleware

auth = AuthMiddleware()
session = auth.create_session('bob', roles=['user'])
sid = session.session_id

# Validate returns the session
result = auth.validate_session(sid)
assert result is not None, 'Expected valid session'
assert result.user_id == 'bob'

# Invalid session returns None
invalid = auth.validate_session('nonexistent-session-id')
assert invalid is None, 'Expected None for invalid session'
print('PASS')
" || fail "J14 test 2: Session validation failed"

# Test 3: Permission checks work
ok "J14 test 3: RoleChecker has_permission enforces RBAC"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.auth import AuthMiddleware

auth = AuthMiddleware()

# admin can rotate_credentials
assert auth.has_permission('admin', 'rotate_credentials'), 'admin should have rotate_credentials'
# user cannot rotate_credentials
assert not auth.has_permission('user', 'rotate_credentials'), 'user should NOT have rotate_credentials'
# Both can read_status
assert auth.has_permission('admin', 'read_status'), 'admin can read_status'
assert auth.has_permission('readonly', 'read_status'), 'readonly can read_status'

print('PASS')
" || fail "J14 test 3: Permission checks failed"

# Test 4: Workspace management via CLI (scripts/control_plane.py)
ok "J14 test 4: Workspace create/list/delete works"
TMP_WS="$(mktemp -d)"
trap 'rm -rf "$TMP_WS"' EXIT

export AGENTIC_WORKSPACES_ROOT="$TMP_WS"

# Create workspace
result=$(python3 "${REPO_ROOT}/scripts/control_plane.py" workspace create --user "testuser" --project "testproj" 2>&1) || fail "workspace create failed: $result"
echo "$result" | grep -q '"action": "created"' || fail "Expected action=created in output: $result"

# List workspaces
result=$(python3 "${REPO_ROOT}/scripts/control_plane.py" workspace list --user "testuser" 2>&1) || fail "workspace list failed: $result"
echo "$result" | grep -q '"workspaces"' || fail "Expected workspaces key in output: $result"

# Delete workspace
result=$(python3 "${REPO_ROOT}/scripts/control_plane.py" workspace delete --user "testuser" --project "testproj" 2>&1) || fail "workspace delete failed: $result"
echo "$result" | grep -q '"action": "deleted"' || fail "Expected action=deleted in output: $result"

echo "PASS" || fail "J14 test 4: Workspace CLI commands failed"

# Test 5: Control plane API status includes auth info (stub mode check)
ok "J14 test 5: ControlPlaneState.status() includes active_sessions"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.api import get_control_state

state = get_control_state()
status = state.status()
assert 'active_sessions' in status, f'Missing active_sessions in status: {list(status.keys())}'
print(f'PASS (active_sessions={status[\"active_sessions\"]})')
" || fail "J14 test 5: Control plane status missing auth info"

# Test 6: Auth audit log captures events
ok "J14 test 6: Audit log captures access events"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.auth import AuthMiddleware

auth = AuthMiddleware()

# Create sessions (generates audit log)
s1 = auth.create_session('alice', roles=['admin'])
s2 = auth.create_session('bob', roles=['user'])

# Validate sessions (more audit entries)
auth.validate_session(s1.session_id)
auth.validate_session('invalid')  # Failed validation

log = auth.get_access_log()
assert len(log) >= 3, f'Expected at least 4 log entries: {len(log)}'

actions = [e['action'] for e in log]
assert 'session_create' in actions or any('create' in a for a in actions), 'Expected create action in log'

print(f'PASS (audit log has {len(log)} entries)')
" || fail "J14 test 6: Audit log failed"

echo ""
echo "=== J14_auth_workspace passed ==="
