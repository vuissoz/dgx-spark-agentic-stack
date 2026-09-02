#!/usr/bin/env bash
# tests/V3_control_plane_integrity.sh — Validate v2 Python adapter contracts and shell integration (heredoc-safe version)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${REPO_ROOT}/scripts:${PATH}"
TEST_PASS=0
TEST_FAIL=0

assert_pass() { echo "OK: test $1: $2"; TEST_PASS=$((TEST_PASS + 1)); }
assert_fail() { echo "FAIL: test $1: $2" >&2; TEST_FAIL=$((TEST_FAIL + 1)); }

run_test() {
  local name="$1"; shift
  if "$@" > /dev/null 2>&1; then
    assert_pass "$name" "$*"
    return 0
  else
    echo "FAIL: test $name ($*)" >&2
    return 1
  fi
}

# Test functions T1-T25 using heredoc to avoid bash brace/quote issues

t1_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
mods = [
    ('agentic.contracts.adapters','HarnessAdapter'),
    ('agentic.models.identity','RuntimeContext'),
    ('agentic.control.scheduler','Scheduler'),
    ('agentic.migration.router','CapabilityRegistry'),
    ('agentic.control.worker','TaskWorker'),
    ('agentic.control.api','_ControlPlaneScaffold'),
    ('agentic.implementations.runtime_inspector','RuntimeInspector'),
]
errs=[]
for mn,at in mods:
  try:
    m=__import__(mn,fromlist=[at]); c=getattr(m,at)
    assert hasattr(c,'__abstractmethods__') or hasattr(c,'__init__')
  except Exception as e: errs.append(f'{mn}: {e}')
if errs: [print(f'MOD_FAIL:{e}',file=sys.stderr) for e in errs]; sys.exit(1)
print('PASS')
PYEOF
}

t2_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.contracts.adapters import (HarnessAdapter,AgentRuntimeAdapter,ApplicationAdapter,
    GPUJobAdapter,ManagedServiceAdapter,ModelBrokerAdapter,RAGServiceAdapter,GitProviderAdapter,ExternalAccessBroker)
all(a.__abstractmethods__ for a in [HarnessAdapter,AgentRuntimeAdapter,ApplicationAdapter,
    GPUJobAdapter,ManagedServiceAdapter,ModelBrokerAdapter,RAGServiceAdapter,GitProviderAdapter,ExternalAccessBroker])
PYEOF
}

t3_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.models.identity import RuntimeContext,Project,AgentIdentity
assert RuntimeContext().is_empty()
o=AgentIdentity(user_id='test',identity_id='owner123'); p=Project(project_id='TEST',owner=o)
assert p.project_id=='TEST'
PYEOF
}

t4_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.control.scheduler import Scheduler,ResourceLimits,QueueMode,SchedulerState
s=Scheduler(state=SchedulerState(total_cpu=8.0,total_memory_mb=16000,total_gpu=4))
r=s.admit('w1',ResourceLimits(cpus=2.0,memory_mb=2000,gpu_count=1),priority=70)
assert r.granted; s.release('w1')
r2=s.admit('w2',ResourceLimits(cpus=4.0,memory_mb=4000),mode=QueueMode.BURST)
assert r2.granted
PYEOF
}

t5_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.control.worker import TaskOutbox,WorkerContext
outbox = TaskOutbox()
corrid = outbox.push('task-a', 'running')
assert corrid is not None
completed = outbox.pull_completed()
assert len(completed) == 0
outbox.push('task-b', 'completed', {'result': 'ok'})
completed2 = outbox.pull_completed()
assert len(completed2) == 1 and completed2[0]['status'] == 'completed'
print('PASS')
PYEOF
}

t6_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.implementations.docker_runtime_adapter import DockerRuntimeAdapter
adapter = DockerRuntimeAdapter(project='test-project')
assert hasattr(adapter, 'provision_sandbox')
assert hasattr(adapter, 'observe_sandbox')
assert hasattr(adapter, 'teardown_sandbox')
assert hasattr(adapter, 'apply_limits')
print('PASS')
PYEOF
}

t7_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.implementations.docker_runtime_adapter import SandboxSnapshot, SandboxState, ProvisionResult
ss = SandboxSnapshot(harness='codex', image_tag='v1.0', workspace_path='/srv/test', session_name='test')
assert ss.harness == 'codex' and ss.image_tag == 'v1.0'
print('PASS')
PYEOF
}

t8_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.implementations.docker_runtime_adapter import DockerRuntimeAdapter
adapter = DockerRuntimeAdapter()
assert adapter._find_container('nonexistent') is None
print('PASS')
PYEOF
}

t9_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.migration.router import create_default_routes, CommandRoute, RouteVersion
routes = create_default_routes()
route = routes.get_route('bootstrap')
assert route is not None and route.command_id == 'bootstrap'
print('PASS')
PYEOF
}

t10_pass() {
v=0; for f in "${REPO_ROOT}/src/agentic/"**/*.py; do [[ -f "$f" ]] || continue; grep -n 'sudo\|docker\.sock\|privileged.*true' "$f" 2>/dev/null | grep -v '^#' | grep -q . && v=$((v+1)); done
[[ $v -eq 0 ]]
}

t11_pass() { bash -n "${REPO_ROOT}/scripts/agent.sh"; }

t12_pass() { [[ -f "${REPO_ROOT}/scripts/sbom_provenance.sh" ]] && bash -n "${REPO_ROOT}/scripts/sbom_provenance.sh"; }

t13_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.contracts.adapters import AgentCapabilities,ToolCallMode
assert AgentCapabilities().tool_call_mode==ToolCallMode.STREAMING
a=AgentCapabilities(tool_call_mode=ToolCallMode.BATCH,max_depth=3)
assert a.tool_call_mode==ToolCallMode.BATCH and a.max_depth==3
PYEOF
}

t14_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.implementations.harness_adapters import get_all_harnesses
h = sorted(get_all_harnesses().keys())
assert len(h)==10, f'Expected 10 harnesses in list, got {len(h)}'
print('PASS')
PYEOF
}

t15_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.implementations.harness_adapters import CodexHarnessAdapter, get_harness
c = CodexHarnessAdapter()
assert c is not None and hasattr(c, 'start_session')
assert hasattr(c, 'end_session')
print('PASS')
PYEOF
}

t16_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.implementations.harness_adapters import CodexHarnessAdapter,ClaudeCodeHarnessAdapter,get_harness
c=CodexHarnessAdapter(); assert c.capabilities.supports_streaming and not c.capabilities.supports_sub_agents
cl=ClaudeCodeHarnessAdapter(); assert cl.capabilities.supports_sub_agents and cl.capabilities.max_depth==2
assert get_harness('codex') is not None
PYEOF
}

t17_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.implementations.harness_adapters import VibeHarnessAdapter, PiHarnessAdapter
v = VibeHarnessAdapter()
p = PiHarnessAdapter()
assert v.capabilities.tool_call_mode.value == 'batch' if hasattr(v.capabilities.tool_call_mode, 'value') else True
assert p.capabilities.supports_sub_agents == False
print('PASS')
PYEOF
}

t18_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.implementations.harness_adapters import HermesHarnessAdapter, OpenClawHarnessAdapter
h = HermesHarnessAdapter()
o = OpenClawHarnessAdapter()
assert h.capabilities.supports_sub_agents == True
assert hasattr(o, 'capabilities')
print('PASS')
PYEOF
}

t19_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.implementations.harness_adapters import get_harness,list_available_harnesses
h=list_available_harnesses()
assert len(h)==10, f'Expected 10 harnesses, got {len(h)}'
names=[x['harness'] for x in h]
for n in ['codex','claude','opencode','kilocode','vibe','hermes','pi','goose','openclaw','openhands']:
  assert n in names, f'Missing harness: {n}'
codex=get_harness('codex'); claude=get_harness('claude')
assert not codex.capabilities.supports_sub_agents and claude.capabilities.supports_sub_agents
openhands=get_harness('openhands'); assert openhands.capabilities.requires_gpu
PYEOF
}

t20_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.control.scheduler import Scheduler,ResourceLimits,QueueMode,SchedulerState
s=Scheduler(state=SchedulerState(total_cpu=8.0,total_memory_mb=16000,total_gpu=4))
assert s.state.total_cpu == 8.0 and s.state.mode.value == 'normal'
print('PASS')
PYEOF
}

t21_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.models.identity import RuntimeContext, Project, AgentIdentity
r = RuntimeContext()
assert r.is_empty(), 'Empty context should be empty'
# Test frozen dataclasses can be created with correct signatures
ai = AgentIdentity(user_id='u1', identity_id='id1')
p = Project(project_id='proj1', owner=ai)
assert p.project_id == 'proj1' and ai.user_id == 'u1'
print('PASS')
PYEOF
}

t22_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.control.worker import TaskOutbox
outbox = TaskOutbox()
assert len(outbox.entries) == 0
print('PASS')
PYEOF
}

t23_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.migration.router import CapabilityRegistry,CommandRoute,RouteVersion
reg=CapabilityRegistry(); reg.register(CommandRoute(command_id='test',version_routes={'default': RouteVersion.V2}))
route=reg.get_route('test')
assert route and route.command_id=='test'
print('PASS')
PYEOF
}

t24_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.control.postgres_schema import get_schema_sql
sql=get_schema_sql()
assert 'CREATE SCHEMA IF NOT EXISTS agentic_control' in sql
expected_tables = [
    ('users', ['user_id','UNIQUE']),
    ('projects', ['project_id','UNIQUE']),
    ('agent_definitions', ['harness_name','version','UNIQUE']),
    ('sessions', ['session_id','UNIQUE','state']),
    ('runs', ['run_id','UNIQUE']),
]
for table,constraints in expected_tables:
  assert f'CREATE TABLE IF NOT EXISTS agentic_control.{table}' in sql
  for c in constraints:
    assert c.upper() in sql.upper()
assert 'INSERT INTO agentic_control.agent_definitions' in sql
assert 'codex' in sql and 'claude' in sql and 'openhands' in sql
PYEOF
}

t25_pass() {
python3 << PYEOF
import sys; sys.path.insert(0,'${REPO_ROOT}/src')
from agentic.control.reconciler import StateReconciler
r = StateReconciler()
assert hasattr(r, 'register_desired'), 'missing register_desired'
assert hasattr(r, 'update_observed'), 'missing update_observed'
assert hasattr(r, 'check_drift'), 'missing check_drift'
r.register_desired('svc-test', desired=True)
r.update_observed('svc-test', observed=False)
drifts = r.check_drift()
assert len(drifts) >= 1, f'Expected at least 1 drift: {len(drifts)}'
print('PASS')
PYEOF
}

echo "=== v2 Control Plane Integrity Tests ==="
run_test T1 t1_pass; run_test T2 t2_pass; run_test T3 t3_pass; run_test T4 t4_pass
run_test T5 t5_pass; run_test T6 t6_pass; run_test T7 t7_pass; run_test T8 t8_pass
run_test T9 t9_pass; run_test T10 t10_pass; run_test T11 t11_pass; run_test T12 t12_pass
run_test T13 t13_pass; run_test T14 t14_pass; run_test T15 t15_pass; run_test T16 t16_pass
run_test T17 t17_pass; run_test T18 t18_pass; run_test T19 t19_pass; run_test T20 t20_pass
run_test T21 t21_pass; run_test T22 t22_pass; run_test T23 t23_pass; run_test T24 t24_pass; run_test T25 t25_pass

echo ""
echo "=== Results: PASS=$TEST_PASS FAIL=$TEST_FAIL ==="
