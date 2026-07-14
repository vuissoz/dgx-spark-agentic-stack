#!/usr/bin/env bash
# tests/J10_reconciler_loop.sh — Validate StateReconciler (§3.1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_cmd python3

ok "J10 test 1: reconciler module imports and satisfies contract"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.reconciler import StateReconciler, OutboxReconciler, DriftReport
r = StateReconciler()
assert hasattr(r, 'register_desired'), 'missing register_desired()'
assert hasattr(r, 'update_observed'), 'missing update_observed()'
assert hasattr(r, 'check_drift'), 'missing check_drift()'
assert hasattr(r, 'reconcile'), 'missing reconcile()'
assert hasattr(r, 'register_reconciler'), 'missing register_reconciler()'
print('PASS')
" || fail "J10 test 1: reconciler contract violation"

ok "J10 test 2: drift detection identifies unhealthy components"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.reconciler import StateReconciler
r = StateReconciler()
r.register_desired('svc-a', desired=True)
r.update_observed('svc-a', observed=True)
r.register_desired('svc-b', desired=True)  # Register desired state for svc-b
r.update_observed('svc-b', observed=False)  # Observed is down → drift!
drifts = r.check_drift()
assert len(drifts) == 1, f'Expected 1 drift, got {len(drifts)}: {[d.component_id for d in drifts]}'
assert drifts[0].component_id == 'svc-b', f'Wrong component: {drifts[0].component_id}'
print('PASS')
" || fail "J10 test 2: drift detection failed"

ok "J10 test 3: reconciler integrates with worker outbox pattern"
python3 -c "
import sys; import asyncio; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.reconciler import OutboxReconciler
from agentic.control.worker import TaskOutbox

outbox = TaskOutbox()
# Register desired state BEFORE pushing to outbox (mimics real scenario)
reconciler = OutboxReconciler(worker_outbox=outbox)
reconciler.register_desired('task-1', desired=True)
reconciler.register_desired('task-2', desired=True)

# Simulate completed/failed tasks
outbox.push('task-1', 'completed', {'status': 'ok'}, correlation_id='corr-1')
outbox.push('task-2', 'failed', {'error': 'boom'}, correlation_id='corr-2')

result = asyncio.run(reconciler.reconcile_from_outbox())
# task-1 completed → observed=True matches desired=True → no drift
# task-2 failed → observed=False vs desired=True → 1 drift
assert len(result) == 1, f'Expected 1 drift (task-2 unhealthy), got {len(result)}: {[r.component_id for r in result]}'
assert result[0].component_id == 'task-2', f'Wrong component: {result[0].component_id}'
print('PASS')
" || fail "J10 test 3: outbox integration failed"

ok "J10 test 4: auto-reconciliation applies corrective action when registered"
python3 -c "
import sys; asyncio = __import__('asyncio'); sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.reconciler import StateReconciler

r = StateReconciler()
r.register_desired('web-ui', desired=True)
r.update_observed('web-ui', observed=False)

reconciled = False
def fix_web_ui(comp_id):
    global reconciled
    if comp_id == 'web-ui':
        r.update_observed(comp_id, observed=True)
        reconciled = True
    return reconciled

r.register_reconciler(fix_web_ui)
import asyncio as _aio
drifts = _aio.run(r.reconcile())

assert reconciled, 'Auto-reconciliation did not trigger'
# After reconciliation, drift should be cleared or marked resolved
resolved = [d for d in r.drift_history if d.action_taken == 'reconciled']
assert len(resolved) >= 1, 'Expected at least 1 reconciled entry in history'
print('PASS')
" || fail "J10 test 4: auto-reconciliation failed"

ok "J10 test 5: reconcile_from_outbox clears processed entries"
python3 -c "
import sys; asyncio = __import__('asyncio'); sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.control.reconciler import OutboxReconciler
from agentic.control.worker import TaskOutbox

outbox = TaskOutbox()
outbox.push('task-cleanup', 'completed', {}, correlation_id='corr-clear-1')

reconciler = OutboxReconciler(worker_outbox=outbox)
asyncio.run(reconciler.reconcile_from_outbox())

# After reconciliation, completed entries should be cleared
remaining = [e for e in outbox.entries if e['correlation_id'] == 'corr-clear-1']
assert len(remaining) == 0, f'Entry not cleared: {len(remaining)} remaining'
print('PASS')
" || fail "J10 test 5: outbox entry clearing failed"

echo ""
echo "=== J10_reconciler_loop passed ==="
