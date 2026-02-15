#!/usr/bin/env bash
set -euo pipefail

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
AGENTIC_COMPOSE_PROJECT="${AGENTIC_COMPOSE_PROJECT:-agentic}"
AGENTIC_NETWORK="${AGENTIC_NETWORK:-agentic}"
RAG_DOCS_DIR="${RAG_DOCS_DIR:-${AGENTIC_ROOT}/rag/docs}"
RAG_COLLECTION="${RAG_COLLECTION:-agentic_docs}"
RAG_EMBED_MODEL="${RAG_EMBED_MODEL:-nomic-embed-text}"
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

  [[ -d "${RAG_DOCS_DIR}" ]] || die "docs directory not found: ${RAG_DOCS_DIR}"

  local gate_url="${OLLAMA_GATE_URL:-}"
  local qdrant_url="${QDRANT_URL:-}"

  if [[ -z "${gate_url}" ]]; then
    gate_url="http://$(service_ip ollama-gate):11435"
  fi
  if [[ -z "${qdrant_url}" ]]; then
    qdrant_url="http://$(service_ip qdrant):6333"
  fi

  python3 - "${RAG_DOCS_DIR}" "${qdrant_url}" "${gate_url}" "${RAG_COLLECTION}" "${RAG_EMBED_MODEL}" "${RAG_GATE_DRY_RUN}" "${RAG_GATE_TIMEOUT_SECONDS}" <<'PY'
import hashlib
import json
import pathlib
import sys
import urllib.error
import urllib.request

docs_dir = pathlib.Path(sys.argv[1])
qdrant_url = sys.argv[2].rstrip("/")
gate_url = sys.argv[3].rstrip("/")
collection = sys.argv[4]
model = sys.argv[5]
dry_run = sys.argv[6] in ("1", "true", "True", "yes", "on")
timeout_seconds = float(sys.argv[7])

doc_paths = sorted([p for p in docs_dir.glob("*.txt") if p.is_file()])
if not doc_paths:
    raise SystemExit(f"ERROR: no .txt files found in {docs_dir}")


def request_json(url: str, payload: dict | None = None, headers: dict | None = None) -> dict:
    body = None
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=req_headers, method="POST" if payload is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout_seconds) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"ERROR: HTTP {exc.code} on {url}: {detail}") from exc


def embedding_for_text(text: str) -> list[float]:
    payload = {"model": model, "input": text}
    headers = {"X-Agent-Session": "rag-ingest", "X-Agent-Project": "rag"}
    if dry_run:
        headers["X-Gate-Dry-Run"] = "1"
    response = request_json(f"{gate_url}/v1/embeddings", payload=payload, headers=headers)
    data = response.get("data", [])
    if not data or not isinstance(data[0], dict):
        raise SystemExit("ERROR: invalid embedding response from gate")
    vector = data[0].get("embedding")
    if not isinstance(vector, list) or not vector:
        raise SystemExit("ERROR: missing embedding vector in gate response")
    return [float(x) for x in vector]


def stable_point_id(path: pathlib.Path) -> int:
    digest = hashlib.sha256(path.as_posix().encode("utf-8")).hexdigest()[:16]
    return int(digest, 16)


vectors: list[tuple[pathlib.Path, list[float], str]] = []
for doc_path in doc_paths:
    content = doc_path.read_text(encoding="utf-8").strip()
    if not content:
        continue
    vectors.append((doc_path, embedding_for_text(content), content))

if not vectors:
    raise SystemExit("ERROR: all candidate docs are empty")

vector_size = len(vectors[0][1])
request_json(
    f"{qdrant_url}/collections/{collection}",
    payload={
        "vectors": {
            "size": vector_size,
            "distance": "Cosine",
            "on_disk": False,
        }
    },
)

indexed = 0
for doc_path, vector, content in vectors:
    request_json(
        f"{qdrant_url}/collections/{collection}/points",
        payload={
            "points": [
                {
                    "id": stable_point_id(doc_path),
                    "vector": vector,
                    "payload": {
                        "path": doc_path.name,
                        "text": content[:8000],
                    },
                }
            ]
        },
    )
    indexed += 1

print(f"OK: rag ingest completed collection={collection} indexed={indexed} dry_run={str(dry_run).lower()}")
PY
}

main "$@"
