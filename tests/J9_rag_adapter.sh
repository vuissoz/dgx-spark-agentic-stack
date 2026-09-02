#!/usr/bin/env bash
# tests/J9_rag_adapter.sh — Validate RAGServiceAdapter implementation (PLAN.md §12.2)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_cmd python3

ok "J9 test 1: RAG adapter module imports and satisfies contract"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.contracts.adapters import RAGServiceAdapter as ABC
from agentic.implementations.rag_adapter import RAGServiceAdapter
r = RAGServiceAdapter()
assert hasattr(r, 'health'), 'missing health()'
assert hasattr(r, 'capabilities'), 'missing capabilities()'
assert hasattr(r, 'config'), 'missing config()'
assert hasattr(r, 'submit_task'), 'missing submit_task()'
assert hasattr(r, 'retrieve'), 'missing retrieve()'
assert hasattr(r, 'snapshot'), 'missing snapshot()'
assert hasattr(r, 'restore'), 'missing restore()'
assert hasattr(r, 'list_collections'), 'missing list_collections()'
assert hasattr(r, 'usage'), 'missing usage()'
print('PASS')
" || fail "J9 test 1: RAG adapter contract violation"

ok "J9 test 2: health() returns healthy=false when no retriever running (expected)"
python3 -c "
import sys, asyncio
sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_adapter import RAGServiceAdapter
r = RAGServiceAdapter(retriever_url='http://127.0.0.1:9999')
result = asyncio.run(r.health())
assert 'healthy' in result, 'health() missing healthy field'
assert result['healthy'] == False, 'Expected unhealthy when no service'
print('PASS')
" || fail "J9 test 2: health check wrong response"

ok "J9 test 3: capabilities() returns expected structure"
python3 -c "
import sys, asyncio
sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_adapter import RAGServiceAdapter
r = RAGServiceAdapter()
result = asyncio.run(r.capabilities())
assert result.get('dense_index') == 'qdrant', f'Expected qdrant dense_index: {result}'
assert result.get('collection_filtering') == True, 'Should support collection filtering (§12.3)'
assert result.get('snapshot_restore') == True, 'Should support snapshot/restore (§12.5)'
print('PASS')
" || fail "J9 test 3: capabilities wrong structure"

ok "J9 test 4: submit_task() returns task_id and status"
python3 -c "
import sys, asyncio
sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_adapter import RAGServiceAdapter
r = RAGServiceAdapter()
result = asyncio.run(r.submit_task({'type': 'ingest', 'source_path': '/tmp/docs'}))
assert 'task_id' in result, 'submit_task missing task_id'
assert result['status'] == 'submitted', f'status should be submitted: {result}'
print('PASS')
" || fail "J9 test 4: submit_task wrong response"

ok "J9 test 5: config() returns non-sensitive configuration"
python3 -c "
import sys, asyncio
sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_adapter import RAGServiceAdapter
r = RAGServiceAdapter()
result = asyncio.run(r.config())
assert 'retriever_url' in result, 'config missing retriever_url'
assert 'collection' in result, 'config missing collection'
print('PASS')
" || fail "J9 test 5: config returns unexpected data"

ok "J9 test 6: snapshot() returns structured result (graceful failure)"
python3 -c "
import sys, asyncio
sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_adapter import RAGServiceAdapter
r = RAGServiceAdapter(retriever_url='http://127.0.0.1:9999')
result = asyncio.run(r.snapshot())
assert 'schema' in result or 'error' in result, 'snapshot should have schema or error'
print('PASS')
" || fail "J9 test 6: snapshot crashes on failure"

ok "J9 test 7: retrieve() returns empty list when no service (graceful degradation)"
python3 -c "
import sys, asyncio
sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_adapter import RAGServiceAdapter
r = RAGServiceAdapter(retriever_url='http://127.0.0.1:9999')
result = asyncio.run(r.retrieve('test query', project='personal'))
assert isinstance(result, list), 'retrieve should return list'
print('PASS')
" || fail "J9 test 7: retrieve not returning list"

ok "J9 test 8: restore() returns structured result with status"
python3 -c "
import sys, asyncio
sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_adapter import RAGServiceAdapter
r = RAGServiceAdapter(retriever_url='http://127.0.0.1:9999')
result = asyncio.run(r.restore())
assert 'schema' in result, 'restore should have schema'
assert 'status' in result, 'restore should have status'
assert result.get('schema') == 'agentic.rag.restore.v1', f'Expected restore schema: {result}'
print('PASS')
" || fail "J9 test 8: restore crashes or wrong response"

ok "J9 test 9: restore() with snapshot_id returns correct snapshot_id"
python3 -c "
import sys, asyncio
sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_adapter import RAGServiceAdapter
r = RAGServiceAdapter(retriever_url='http://127.0.0.1:9999')
result = asyncio.run(r.restore('snap-123'))
assert result.get('snapshot_id') == 'snap-123', f'Expected snapshot_id snap-123: {result}'
print('PASS')
" || fail "J9 test 9: restore with snapshot_id wrong"

ok "J9 test 10: list_collections() returns list of collections"
python3 -c "
import sys, asyncio
sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_adapter import RAGServiceAdapter
r = RAGServiceAdapter(retriever_url='http://127.0.0.1:9999')
result = asyncio.run(r.list_collections())
assert isinstance(result, list), f'list_collections should return list: {type(result)}'
assert len(result) > 0, 'Should return at least one collection'
assert 'name' in result[0], 'Collection should have name field'
print('PASS')
" || fail "J9 test 10: list_collections wrong response"

ok "J9 test 11: usage() returns structured usage statistics"
python3 -c "
import sys, asyncio
sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_adapter import RAGServiceAdapter
r = RAGServiceAdapter(retriever_url='http://127.0.0.1:9999')
result = asyncio.run(r.usage())
assert 'schema' in result, 'usage should have schema'
assert result.get('schema') == 'agentic.rag.usage.v1', f'Expected usage schema: {result}'
print('PASS')
" || fail "J9 test 11: usage wrong response"

ok "J9 test 12: usage() with project filter includes project field"
python3 -c "
import sys, asyncio
sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.rag_adapter import RAGServiceAdapter
r = RAGServiceAdapter(retriever_url='http://127.0.0.1:9999')
result = asyncio.run(r.usage(project='test-project'))
assert result.get('project') == 'test-project', f'Expected project filter: {result}'
print('PASS')
" || fail "J9 test 12: usage with project filter wrong"

echo ""
echo "=== J9_rag_adapter passed ==="
