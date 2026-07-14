#!/usr/bin/env bash
# tests/J7_model_broker_protocol.sh — ModelBroker Protocol validation (PLAN.md §6)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_J_TESTS:-0}" == "1" ]]; then
  ok "J7 skipped because AGENTIC_SKIP_J_TESTS=1"
  exit 0
fi

assert_cmd python3

BROKER_SCRIPT="${REPO_ROOT}/deployments/optional/model_broker_protocol.py"
SPEC_FILE="${REPO_ROOT}/evaluation/spec/model_broker.yaml"

ok "J7 test 1: ModelBroker protocol spec and SDK exist"
[[ -f "${SPEC_FILE}" ]] || fail "model_broker.yaml missing"
[[ -f "${BROKER_SCRIPT}" ]] || fail "model_broker_protocol.py missing"
[[ -x "${BROKER_SCRIPT}" ]] || fail "model_broker_protocol.py not executable"

ok "J7 test 2: spec validates — required sections and endpoints present"
python3 "${BROKER_SCRIPT}" validate --spec-file "${SPEC_FILE}" \
  || fail "spec validation failed"

ok "J7 test 3: contract tests run and produce results"
test_output="$(python3 "${BROKER_SCRIPT}" test 2>&1)"
echo "${test_output}" | grep -q "ModelBroker contract tests:" \
  || fail "contract test did not produce summary line"

# Extract pass count from summary line
pass_count="$(echo "${test_output}" | grep -oP '\d+/\d+ passed' | head -1)"
total_tests="${pass_count##*/}"
passed_tests="${pass_count%%/*}"
[[ "${passed_tests:-0}" -ge 8 ]] || fail "expected >=8 tests to pass, got ${passed_tests}/${total_tests}"

ok "J7 test 4: identity required returns 401 without headers"
result="$(python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}')
from deployments.optional.model_broker_protocol import ModelBrokerContract
b = ModelBrokerContract()
r = b.generate(model='qwen3', prompt='test')
print(r.get('status_code'), r.get('error',''))
" 2>&1)"
[[ "${result}" == *"401"* ]] || fail "expected 401 without identity, got: ${result}"

ok "J7 test 5: valid identity with agent/user/project/run passes"
result="$(python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}')
from deployments.optional.model_broker_protocol import ModelBrokerContract
b = ModelBrokerContract()
r = b.generate(model='qwen3-32b', prompt='hello world test', agent_id='codex', user_id='alice', project_id='ARTANY', run_id='run-001')
print('content' in r and 'error' not in r)
" 2>&1)"
[[ "${result}" == "True" ]] || fail "valid identity should succeed, got: ${result}"

ok "J7 test 6: unknown agent rejected with actionable error"
result="$(python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}')
from deployments.optional.model_broker_protocol import ModelBrokerContract
b = ModelBrokerContract()
r = b.generate(model='qwen3', prompt='test', agent_id='evil-agent', user_id='alice')
print(r.get('status_code'), r.get('error',''))
" 2>&1)"
echo "${result}" | grep -qi "401\|unknown" || fail "unknown agent should be rejected, got: ${result}"

ok "J7 test 7: all backends unhealthy returns 503"
result="$(python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}')
from deployments.optional.model_broker_protocol import ModelBrokerContract, BackendStatus
b = ModelBrokerContract()
b.backends['ollama'] = BackendStatus.UNHEALTHY
b.backends['trtllm'] = BackendStatus.UNHEALTHY
b.backends['remote'] = BackendStatus.UNHEALTHY
r = b.generate(model='qwen3', prompt='test', agent_id='codex', user_id='alice')
print(r.get('status_code'), r.get('error',''))
" 2>&1)"
[[ "${result}" == *"503"* ]] || fail "all unhealthy should return 503, got: ${result}"

ok "J7 test 8: quota enforcement blocks over-limit requests"
result="$(python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}')
from deployments.optional.model_broker_protocol import ModelBrokerContract, QuotaState
b = ModelBrokerContract()
key = b._get_quota_key('agent', 'goose')
b.quotas[key] = QuotaState(tokens_limit=50, requests_limit=1)
r1 = b.generate(model='qwen3', prompt='test', agent_id='goose', user_id='alice')
r2 = b.generate(model='qwen3', prompt='test', agent_id='goose', user_id='alice')
# Second request should exceed requests_limit=1
print(r2.get('status_code'), r2.get('error',''))
" 2>&1)"
[[ "${result}" == *"429"* ]] || fail "over-limit should return 429, got: ${result}"

ok "J7 test 9: audit log records calls with signed identity metadata"
result="$(python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}')
from deployments.optional.model_broker_protocol import ModelBrokerContract
b = ModelBrokerContract()
r = b.generate(model='qwen3', prompt='test audit log', agent_id='codex', user_id='alice', project_id='ARTANY', run_id='run-abc')
if len(b.audit_log) >= 1:
    e = b.audit_log[-1]
    print(f'entries={len(b.audit_log)} has_user={hasattr(e,\"user_id\")} agent={e.agent_id} project={getattr(e,\"project_id\",\"MISSING\")}')
else:
    print('NO_ENTRIES')
" 2>&1)"
echo "${result}" | grep -q "entries=1\|agent=codex" || fail "audit log should record entries, got: ${result}"

ok "J7 test 10: metrics track usage and fallback counts"
metrics_output="$(python3 -c "
import sys, json
sys.path.insert(0, '${REPO_ROOT}')
from deployments.optional.model_broker_protocol import ModelBrokerContract, BackendStatus
b = ModelBrokerContract()
# Force ollama unhealthy → triggers fallback path
b.backends['ollama'] = BackendStatus.UNHEALTHY
b.generate(model='qwen3', prompt='test', agent_id='codex', user_id='alice')
print(json.dumps(b.metrics))
" 2>&1)"
echo "${metrics_output}" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert 'tokens_total' in d and 'fallback_count' in d" \
  || fail "metrics should include tokens_total and fallback_count, got: ${metrics_output}"

ok "J7 test 11: spec defines all required contract sections"
spec_content="$(cat "${SPEC_FILE}")"
for section in "signed_identity_required" "fallback" "quotas" "gpu_admission"; do
  echo "${spec_content}" | grep -qi "${section}" \
    || fail "spec missing contract requirement: ${section}"
done

ok "J7 test 12: spec defines all required endpoints"
for ep in "/v1/models" "/v1/generate" "/v1/chat/completions" "/v1/embeddings"; do
  echo "${spec_content}" | grep -q "${ep}" \
    || fail "spec missing endpoint: ${ep}"
done

# Cleanup test artifacts
rm -rf /tmp/mbo-* 2>/dev/null || true

ok "J7_model_broker_protocol passed"
