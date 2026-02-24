#!/usr/bin/env bash
set -euo pipefail

AGENTIC_COMPOSE_PROJECT="${AGENTIC_COMPOSE_PROJECT:-agentic}"
AGENTIC_NETWORK="${AGENTIC_NETWORK:-agentic}"
RAG_COLLECTION="${RAG_COLLECTION:-agentic_docs}"
RAG_QUERY_TEXT="${RAG_QUERY_TEXT:-What does this stack provide?}"
RAG_EMBED_MODEL="${RAG_EMBED_MODEL:-qwen3-embedding:0.6b}"
RAG_MIN_HITS="${RAG_MIN_HITS:-1}"
RAG_GATE_DRY_RUN="${RAG_GATE_DRY_RUN:-1}"
RAG_GATE_TIMEOUT_SECONDS="${RAG_GATE_TIMEOUT_SECONDS:-20}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

service_ip() {
  local service="$1"
  local container_id
  container_id="$(docker ps \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}' | head -n 1)"
  [[ -n "${container_id}" ]] || die "service '${service}' is not running"

  docker inspect --format "{{with index .NetworkSettings.Networks \"${AGENTIC_NETWORK}\"}}{{.IPAddress}}{{end}}" "${container_id}"
}

main() {
  require_cmd docker
  require_cmd python3

  local gate_url="${OLLAMA_GATE_URL:-}"
  local qdrant_url="${QDRANT_URL:-}"

  if [[ -z "${gate_url}" ]]; then
    gate_url="http://$(service_ip ollama-gate):11435"
  fi
  if [[ -z "${qdrant_url}" ]]; then
    qdrant_url="http://$(service_ip qdrant):6333"
  fi

  python3 - "${qdrant_url}" "${gate_url}" "${RAG_COLLECTION}" "${RAG_QUERY_TEXT}" "${RAG_EMBED_MODEL}" "${RAG_MIN_HITS}" "${RAG_GATE_DRY_RUN}" "${RAG_GATE_TIMEOUT_SECONDS}" <<'PY'
import json
import hashlib
import math
import re
import sys
import urllib.error
import urllib.request

qdrant_url = sys.argv[1].rstrip("/")
gate_url = sys.argv[2].rstrip("/")
collection = sys.argv[3]
query_text = sys.argv[4]
model = sys.argv[5]
min_hits = int(sys.argv[6])
dry_run = sys.argv[7] in ("1", "true", "True", "yes", "on")
timeout_seconds = float(sys.argv[8])
dry_run_vector_size = 32


def request_json(url: str, payload: dict, headers: dict | None = None) -> dict:
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=req_headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout_seconds) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"ERROR: HTTP {exc.code} on {url}: {detail}") from exc


def deterministic_dry_run_embedding(text: str, vector_size: int | None = None) -> list[float]:
    size = max(16, int(vector_size or dry_run_vector_size))
    normalized = text.strip().lower()
    tokens = re.findall(r"[a-z0-9_]+", normalized)
    if not tokens:
        tokens = [normalized or "empty"]

    vector = [0.0] * size
    for idx, token in enumerate(tokens):
        digest = hashlib.sha256(f"{idx}:{token}".encode("utf-8")).digest()
        bucket = int.from_bytes(digest[:2], "big") % size
        sign = -1.0 if (digest[2] & 1) else 1.0
        weight = 1.0 / float(1 + (idx // 4))
        vector[bucket] += sign * weight

    norm = math.sqrt(sum(value * value for value in vector))
    if norm == 0:
        return [0.0] * size
    return [value / norm for value in vector]


def collection_vector_size() -> int | None:
    req = urllib.request.Request(
        f"{qdrant_url}/collections/{collection}",
        headers={"Content-Type": "application/json"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout_seconds) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"ERROR: HTTP {exc.code} on {qdrant_url}/collections/{collection}: {detail}") from exc
    result = payload.get("result", {})
    config = result.get("config", {}) if isinstance(result, dict) else {}
    params = config.get("params", {}) if isinstance(config, dict) else {}
    vectors = params.get("vectors", {}) if isinstance(params, dict) else {}
    if isinstance(vectors, dict):
        size = vectors.get("size")
        if isinstance(size, int) and size > 0:
            return size
    return None


headers = {"X-Agent-Session": "rag-query", "X-Agent-Project": "rag"}
if dry_run:
    headers["X-Gate-Dry-Run"] = "1"

expected_vector_size = collection_vector_size()

try:
    embed = request_json(
        f"{gate_url}/v1/embeddings",
        payload={"model": model, "input": query_text},
        headers=headers,
    )
    data = embed.get("data", [])
    if not data or not isinstance(data[0], dict):
        raise SystemExit("ERROR: invalid embedding response from gate")
    vector = data[0].get("embedding")
    if not isinstance(vector, list) or not vector:
        raise SystemExit("ERROR: missing query embedding")
except BaseException:
    if dry_run:
        if isinstance(expected_vector_size, int) and expected_vector_size > 0:
            vector = deterministic_dry_run_embedding(query_text, expected_vector_size)
        else:
            vector = deterministic_dry_run_embedding(query_text)
    else:
        raise

if isinstance(expected_vector_size, int) and expected_vector_size > 0 and len(vector) != expected_vector_size:
    if dry_run:
        vector = deterministic_dry_run_embedding(query_text, expected_vector_size)
    else:
        raise SystemExit(
            f"ERROR: query embedding vector size mismatch (expected={expected_vector_size}, got={len(vector)})"
        )

search = request_json(
    f"{qdrant_url}/collections/{collection}/points/search",
    payload={"vector": vector, "limit": max(min_hits, 1)},
)
hits = search.get("result", [])
hit_count = len(hits) if isinstance(hits, list) else 0
if hit_count < min_hits:
    raise SystemExit(f"ERROR: query returned {hit_count} hits, expected at least {min_hits}")

print(f"OK: rag query smoke passed collection={collection} hits={hit_count} dry_run={str(dry_run).lower()}")
PY
}

main "$@"
