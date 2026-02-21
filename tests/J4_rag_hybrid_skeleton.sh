#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

published_retriever="$(docker port "${retriever_cid}" 7111/tcp 2>/dev/null || true)"
published_worker="$(docker port "${worker_cid}" 7112/tcp 2>/dev/null || true)"
[[ -z "${published_retriever}" ]] || fail "rag-retriever must not publish host port 7111 (got: ${published_retriever})"
[[ -z "${published_worker}" ]] || fail "rag-worker must not publish host port 7112 (got: ${published_worker})"
ok "rag retriever/worker have no host-published ports"

retrieval_payload="$(docker exec -i "${retriever_cid}" python3 - <<'PY'
import json
import urllib.request

req = urllib.request.Request(
    "http://127.0.0.1:7111/v1/retrieve",
    data=json.dumps({"query": "bm25 code identifier", "top_k": 8, "request_id": "j4-smoke"}).encode("utf-8"),
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
if payload.get("status") != "skeleton":
    raise SystemExit("rag-retriever skeleton status mismatch")
fusion = payload.get("fusion", {})
if fusion.get("method") != "rrf":
    raise SystemExit("rag-retriever fusion method must default to rrf in skeleton mode")
dense = payload.get("dense", {})
if dense.get("backend") != "qdrant":
    raise SystemExit("rag-retriever dense backend must be qdrant in skeleton mode")
print("OK: rag retrieval skeleton endpoint contract is valid")
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
print("OK: rag worker sees retriever as up")
PY

opensearch_cid="$(service_container_id opensearch || true)"
if [[ -n "${opensearch_cid}" ]]; then
  wait_for_container_ready "${opensearch_cid}" 180 || fail "opensearch (rag-lexical profile) is not ready"
  published_opensearch="$(docker port "${opensearch_cid}" 9200/tcp 2>/dev/null || true)"
  [[ -z "${published_opensearch}" ]] || fail "opensearch must not publish host port 9200 (got: ${published_opensearch})"
  ok "opensearch profile service is internal-only when enabled"
else
  warn "opensearch service not running (expected unless profile rag-lexical is enabled)"
fi

ok "J4_rag_hybrid_skeleton passed"
