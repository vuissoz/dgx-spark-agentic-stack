#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_J_TESTS:-0}" == "1" ]]; then
  ok "J4 skipped because AGENTIC_SKIP_J_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd python3

qdrant_cid="$(require_service_container qdrant)" || exit 1
retriever_cid="$(require_service_container rag-retriever)" || exit 1
worker_cid="$(require_service_container rag-worker)" || exit 1

wait_for_container_ready "${qdrant_cid}" 180 || fail "qdrant is not ready"
wait_for_container_ready "${retriever_cid}" 120 || fail "rag-retriever is not ready"
wait_for_container_ready "${worker_cid}" 120 || fail "rag-worker is not ready"

assert_container_security "${retriever_cid}" || fail "rag-retriever container security baseline failed"
assert_container_security "${worker_cid}" || fail "rag-worker container security baseline failed"

runtime_docs="${AGENTIC_ROOT:-/srv/agentic}/rag/docs"
sentinel_doc="${REPO_ROOT}/examples/rag/corpus/003-lexical-sensitive.txt"
if [[ -f "${sentinel_doc}" && -d "${runtime_docs}" && ! -f "${runtime_docs}/003-lexical-sensitive.txt" ]]; then
  install -m 0640 "${sentinel_doc}" "${runtime_docs}/003-lexical-sensitive.txt" \
    || fail "failed to seed lexical-sensitive RAG corpus into ${runtime_docs}"
fi

published_retriever="$(docker port "${retriever_cid}" 7111/tcp 2>/dev/null || true)"
published_worker="$(docker port "${worker_cid}" 7112/tcp 2>/dev/null || true)"
[[ -z "${published_retriever}" ]] || fail "rag-retriever must not publish host port 7111 (got: ${published_retriever})"
[[ -z "${published_worker}" ]] || fail "rag-worker must not publish host port 7112 (got: ${published_worker})"
ok "rag retriever/worker have no host-published ports"

index_payload="$(docker exec -i "${worker_cid}" python3 - <<'PY'
import json
import urllib.request

req = urllib.request.Request(
    "http://127.0.0.1:7112/v1/index",
    data=json.dumps({"sync": True, "docs_dir": "/docs"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=90) as resp:
    print(resp.read().decode("utf-8"))
PY
)" || fail "failed to trigger synchronous index task on rag-worker"

python3 - "${index_payload}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
if payload.get("status") != "completed":
    raise SystemExit(f"rag-worker /v1/index sync expected status=completed (got={payload.get('status')})")
task = payload.get("task", {})
result = task.get("result", {})
if int(result.get("indexed", 0)) < 1:
    raise SystemExit("rag-worker /v1/index must index at least one document")
print("OK: rag worker indexed docs through async task pipeline")
PY

agent_index_output="$("${REPO_ROOT}/agent" rag index --wait --docs-dir "${runtime_docs}" --timeout-sec 120)" \
  || fail "agent rag index command failed"
printf '%s\n' "${agent_index_output}" | grep -q 'rag index status=completed' \
  || fail "agent rag index output is not actionable: ${agent_index_output}"
printf '%s\n' "${agent_index_output}" | grep -q 'indexed=' \
  || fail "agent rag index output is missing indexed count: ${agent_index_output}"
ok "agent rag index triggers worker indexing and reports task completion"

retrieval_payload="$(docker exec -i "${retriever_cid}" python3 - <<'PY'
import json
import urllib.request

req = urllib.request.Request(
    "http://127.0.0.1:7111/v1/retrieve",
    data=json.dumps({"query": "proxy allowlist security controls", "top_k": 8, "request_id": "j4-smoke"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=10) as resp:
    print(resp.read().decode("utf-8"))
PY
)" || fail "failed to call rag-retriever /v1/retrieve"

[[ -n "${retrieval_payload}" ]] || fail "rag-retriever /v1/retrieve returned an empty payload"

python3 - "${retrieval_payload}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
if payload.get("status") not in {"ok", "partial"}:
    raise SystemExit(f"rag-retriever status mismatch (got={payload.get('status')})")
fusion = payload.get("fusion", {})
if fusion.get("method") != "rrf":
    raise SystemExit("rag-retriever fusion method must default to rrf")
fusion_results = fusion.get("results", [])
if not isinstance(fusion_results, list) or len(fusion_results) < 1:
    raise SystemExit("rag-retriever fusion results must contain at least one hit")
dense = payload.get("dense", {})
if dense.get("backend") != "qdrant":
    raise SystemExit("rag-retriever dense backend must be qdrant")
if dense.get("status") != "ok":
    raise SystemExit(f"rag-retriever dense status must be ok after indexing (got={dense.get('status')})")
dense_hits = dense.get("hits", [])
if not isinstance(dense_hits, list) or len(dense_hits) < 1:
    raise SystemExit("rag-retriever dense hits must contain at least one result")
lexical = payload.get("lexical", {})
if lexical.get("backend") == "opensearch" and lexical.get("status") == "ok":
    lexical_hits = lexical.get("hits", [])
    if not isinstance(lexical_hits, list) or len(lexical_hits) < 1:
        raise SystemExit("rag-retriever lexical hits must contain at least one result when opensearch is enabled")
print("OK: rag retrieval full endpoint contract is valid")
PY

lexical_sensitive_payload="$(docker exec -i "${retriever_cid}" python3 - <<'PY'
import json
import urllib.request

req = urllib.request.Request(
    "http://127.0.0.1:7111/v1/retrieve",
    data=json.dumps({
        "query": "RAG_J4_SENTINEL --rag-index v4.2.17 DGX_RAG_PIPELINE",
        "top_k": 8,
        "request_id": "j4-lexical-sensitive",
    }).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=10) as resp:
    print(resp.read().decode("utf-8"))
PY
)" || fail "failed to call rag-retriever lexical-sensitive query"

python3 - "${lexical_sensitive_payload}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
fusion_results = payload.get("fusion", {}).get("results", [])
if not isinstance(fusion_results, list) or not fusion_results:
    raise SystemExit("lexical-sensitive query must return fused hits")
paths = {str(hit.get("source_path", "")) for hit in fusion_results}
if "003-lexical-sensitive.txt" not in paths:
    raise SystemExit(f"expected lexical-sensitive corpus hit in fusion results, got paths={sorted(paths)}")
rerank = payload.get("rerank", {})
if rerank.get("status") != "disabled" or rerank.get("enabled") is not False:
    raise SystemExit(f"rerank default must be disabled, got={rerank}")
lexical = payload.get("lexical", {})
if lexical.get("backend") == "opensearch" and lexical.get("status") == "ok":
    lexical_paths = {str(hit.get("source_path", "")) for hit in lexical.get("hits", [])}
    if "003-lexical-sensitive.txt" not in lexical_paths:
        raise SystemExit(f"opensearch lexical hits must include sentinel doc, got paths={sorted(lexical_paths)}")
print("OK: lexical-sensitive RAG query returns the sentinel technical-token document")
PY

rerank_payload="$(docker exec -i "${retriever_cid}" python3 - <<'PY'
import json
import urllib.request

req = urllib.request.Request(
    "http://127.0.0.1:7111/v1/retrieve",
    data=json.dumps({
        "query": "RAG_J4_SENTINEL --rag-index v4.2.17 DGX_RAG_PIPELINE",
        "top_k": 8,
        "request_id": "j4-rerank-enabled",
        "rerank": {"enabled": True, "backend": "lexical", "top_n": 3, "candidates": 8},
    }).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=10) as resp:
    print(resp.read().decode("utf-8"))
PY
)" || fail "failed to call rag-retriever rerank-enabled query"

python3 - "${rerank_payload}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
rerank = payload.get("rerank", {})
if rerank.get("enabled") is not True or rerank.get("status") != "ok":
    raise SystemExit(f"rerank enabled path must return status=ok, got={rerank}")
results = rerank.get("results", [])
if not isinstance(results, list) or not results:
    raise SystemExit("rerank enabled path must return reranked results")
if str(results[0].get("source_path", "")) != "003-lexical-sensitive.txt":
    raise SystemExit(f"reranker should rank sentinel doc first, got first={results[0]}")
final_results = payload.get("results", [])
if not isinstance(final_results, list) or not final_results:
    raise SystemExit("top-level results must expose final reranked candidates")
print("OK: optional lexical reranker refines fused candidates deterministically")
PY

rerank_degraded_payload="$(docker exec -i "${retriever_cid}" python3 - <<'PY'
import json
import urllib.request

req = urllib.request.Request(
    "http://127.0.0.1:7111/v1/retrieve",
    data=json.dumps({
        "query": "RAG_J4_SENTINEL",
        "top_k": 4,
        "request_id": "j4-rerank-degraded",
        "rerank": {"enabled": True, "backend": "missing-backend"},
    }).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=10) as resp:
    print(resp.read().decode("utf-8"))
PY
)" || fail "failed to call rag-retriever rerank-degraded query"

python3 - "${rerank_degraded_payload}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
rerank = payload.get("rerank", {})
if rerank.get("status") != "degraded":
    raise SystemExit(f"unsupported reranker backend must degrade explicitly, got={rerank}")
if not payload.get("fusion", {}).get("results"):
    raise SystemExit("reranker degraded path must preserve fused results")
print("OK: unsupported reranker backend degrades without dropping fused results")
PY

worker_health_payload="$(docker exec -i "${worker_cid}" python3 - <<'PY'
import urllib.request
with urllib.request.urlopen("http://127.0.0.1:7112/healthz", timeout=10) as resp:
    print(resp.read().decode("utf-8"))
PY
)" || fail "failed to call rag-worker /healthz"

python3 - "${worker_health_payload}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
if payload.get("status") != "ok":
    raise SystemExit("rag-worker health status must be ok")
if payload.get("retriever_status") != "up":
    raise SystemExit("rag-worker must report retriever_status=up")
if not isinstance(payload.get("queue_depth"), int):
    raise SystemExit("rag-worker must report queue_depth as an integer")
print("OK: rag worker sees retriever as up")
PY

retriever_audit_count="$(docker exec "${retriever_cid}" sh -lc 'set -- $(wc -l /logs/retrieval.audit.jsonl 2>/dev/null); printf "%s" "${1:-0}"')"
[[ -n "${retriever_audit_count}" ]] || fail "rag-retriever audit log count is missing"
[[ "${retriever_audit_count}" -ge 1 ]] || fail "rag-retriever audit log must contain at least one event"
ok "rag-retriever audit log is populated"

opensearch_cid="$(service_container_id opensearch || true)"
if [[ -n "${opensearch_cid}" ]]; then
  wait_for_container_ready "${opensearch_cid}" 180 || fail "opensearch (rag-lexical profile) is not ready"
  published_opensearch="$(docker port "${opensearch_cid}" 9200/tcp 2>/dev/null || true)"
  [[ -z "${published_opensearch}" ]] || fail "opensearch must not publish host port 9200 (got: ${published_opensearch})"
  bootstrap_payload="$(docker exec -i "${worker_cid}" python3 - <<'PY'
import json
import urllib.request

req = urllib.request.Request(
    "http://127.0.0.1:7112/v1/bootstrap",
    data=b"{}",
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=90) as resp:
    print(resp.read().decode("utf-8"))
PY
)" || fail "failed to explicitly bootstrap opensearch lexical index"
  python3 - "${bootstrap_payload}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
if payload.get("status") != "ok":
    raise SystemExit(f"opensearch bootstrap status mismatch: {payload}")
result = payload.get("result", {})
if result.get("backend") != "opensearch" or result.get("status") not in {"created", "exists"}:
    raise SystemExit(f"opensearch bootstrap result mismatch: {result}")
print("OK: opensearch lexical index bootstrap is explicit and repeatable")
PY
  ok "opensearch profile service is internal-only when enabled"
else
  warn "opensearch service not running (expected unless profile rag-lexical is enabled)"
fi

ok "J4_rag_hybrid_skeleton passed (full mode checks)"
