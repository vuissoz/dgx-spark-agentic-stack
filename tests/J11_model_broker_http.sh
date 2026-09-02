#!/usr/bin/env bash
# tests/J11_model_broker_http.sh — Validate ModelBroker HTTP clients (§6, §17)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_cmd python3

ok "J11 test 1: model_broker_client module imports all classes"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.model_broker_client import (
    OllamaGateClient, TRTLLMClient, ModelBrokerWithHTTP,
    ModelRequest, ModelResponse, BackendConfig
)
assert hasattr(OllamaGateClient, 'health_check')
assert hasattr(OllamaGateClient, 'list_models')
assert hasattr(OllamaGateClient, 'generate')
assert hasattr(TRTLLMClient, 'generate')
assert hasattr(ModelBrokerWithHTTP, 'route_request')
assert hasattr(ModelBrokerWithHTTP, 'sync_model_catalog')
print('PASS')
" || fail "J11 test 1: imports failed"

ok "J11 test 2: ModelRequest and ModelResponse dataclasses work"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.model_broker_client import ModelRequest, ModelResponse
req = ModelRequest(model_name='qwen3', messages=[{'role': 'user', 'content': 'hi'}])
assert req.model_name == 'qwen3' and len(req.messages) == 1
resp = ModelResponse(id='test-1', model='qwen3', content='hello')
assert resp.id == 'test-1' and resp.content == 'hello'
print('PASS')
" || fail "J11 test 2: dataclass tests failed"

ok "J11 test 3: ModelBrokerWithHTTP initializes with default catalog"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.model_broker_client import ModelBrokerWithHTTP
broker = ModelBrokerWithHTTP()
assert 'qwen3-coder:30b' in broker.model_catalog
assert len(broker.model_catalog) >= 2
print('PASS')
" || fail "J11 test 3: catalog init failed"

ok "J11 test 4: health_check returns structure (may be unhealthy without service)"
python3 -c "
import sys, asyncio; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.model_broker_client import ModelBrokerWithHTTP
broker = ModelBrokerWithHTTP()
# Without aiohttp, health returns error dict (graceful degradation)
result = asyncio.run(broker.health_check())
assert 'schema' in result or 'ollama_gate' in result
print('PASS')
" || fail "J11 test 4: health check failed"

echo ""
echo "=== J11_model_broker_http passed ==="
