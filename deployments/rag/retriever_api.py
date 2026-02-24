#!/usr/bin/env python3
"""Hybrid retrieval orchestrator (dense + lexical + fusion) for Step J4."""

from __future__ import annotations

import json
import os
import hashlib
import math
import re
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


HOST = os.environ.get("RAG_RETRIEVER_HOST", "0.0.0.0")
PORT = int(os.environ.get("RAG_RETRIEVER_PORT", "7111"))
SCHEMA_PATH = Path(os.environ.get("RAG_SCHEMA_PATH", "/config/document.schema.json"))
STATE_DIR = Path(os.environ.get("RAG_RETRIEVER_STATE_DIR", "/state"))
LOG_DIR = Path(os.environ.get("RAG_RETRIEVER_LOG_DIR", "/logs"))
QDRANT_URL = os.environ.get("RAG_QDRANT_URL", "http://qdrant:6333").rstrip("/")
GATE_URL = os.environ.get("RAG_GATE_URL", "http://ollama-gate:11435").rstrip("/")
OPENSEARCH_URL = os.environ.get("RAG_OPENSEARCH_URL", "http://opensearch:9200").rstrip("/")
COLLECTION = os.environ.get("RAG_COLLECTION", "agentic_docs")
LEXICAL_INDEX = os.environ.get("RAG_LEXICAL_INDEX", COLLECTION)
DENSE_BACKEND = os.environ.get("RAG_DENSE_BACKEND", "qdrant")
LEXICAL_BACKEND = os.environ.get("RAG_LEXICAL_BACKEND", "disabled")
FUSION_METHOD = os.environ.get("RAG_FUSION_METHOD", "rrf")
RRF_K = int(os.environ.get("RAG_RRF_K", "60"))
EMBED_MODEL = os.environ.get("RAG_EMBED_MODEL", "qwen3-embedding:0.6b")
REQUEST_TIMEOUT_SEC = float(os.environ.get("RAG_HTTP_TIMEOUT_SEC", "10"))
TOP_K_MAX = int(os.environ.get("RAG_TOP_K_MAX", "32"))
DRY_RUN_VECTOR_SIZE = max(16, int(os.environ.get("RAG_DRY_RUN_VECTOR_SIZE", "32")))


def is_truthy(value: str | None) -> bool:
    if value is None:
        return False
    return value.strip().lower() in {"1", "true", "yes", "on"}


GATE_DRY_RUN = is_truthy(os.environ.get("RAG_GATE_DRY_RUN", "1"))
STATE_WRITE_WARNED: set[str] = set()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_schema() -> dict:
    if not SCHEMA_PATH.is_file():
        return {"status": "missing", "path": str(SCHEMA_PATH)}
    try:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    except Exception as exc:  # pragma: no cover - defensive
        return {"status": "error", "path": str(SCHEMA_PATH), "error": str(exc)}
    return {"status": "loaded", "path": str(SCHEMA_PATH), "schema": schema}


SCHEMA_INFO = load_schema()


def write_state(name: str, value: str) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        (STATE_DIR / name).write_text(value + "\n", encoding="utf-8")
    except OSError as exc:
        # State tracking is best-effort; do not fail request handlers on disk permission drift.
        if name not in STATE_WRITE_WARNED:
            print(f"WARN: unable to write retriever state '{name}': {exc}", flush=True)
            STATE_WRITE_WARNED.add(name)


def append_audit(event: dict) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with (LOG_DIR / "retrieval.audit.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=True) + "\n")


def request_json(
    url: str,
    payload: dict | None = None,
    *,
    method: str | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = REQUEST_TIMEOUT_SEC,
) -> dict:
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)

    body = None
    req_method = method
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        req_method = req_method or "POST"
    else:
        req_method = req_method or "GET"

    request = urllib.request.Request(url, data=body, headers=req_headers, method=req_method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} {url}: {detail[:400]}") from exc
    except Exception as exc:
        raise RuntimeError(f"request failed {url}: {exc}") from exc

    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid json response from {url}: {exc}") from exc


def extract_payload_text(payload: dict) -> str:
    text = payload.get("text")
    if isinstance(text, str) and text.strip():
        return text.strip()
    return ""


def deterministic_dry_run_embedding(text: str, *, vector_size: int | None = None) -> list[float]:
    size = max(16, int(vector_size or DRY_RUN_VECTOR_SIZE))
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
    try:
        response = request_json(f"{QDRANT_URL}/collections/{COLLECTION}", method="GET")
    except Exception:
        return None

    result = response.get("result")
    if not isinstance(result, dict):
        return None
    config = result.get("config")
    if not isinstance(config, dict):
        return None
    params = config.get("params")
    if not isinstance(params, dict):
        return None
    vectors = params.get("vectors")
    if isinstance(vectors, dict):
        size = vectors.get("size")
        if isinstance(size, int) and size > 0:
            return size
    return None


def extract_doc_id(payload: dict, fallback_id: str) -> str:
    for key in ("doc_id", "source_path", "path", "file_path"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return fallback_id


def extract_chunk_id(payload: dict, doc_id: str, fallback_id: str) -> str:
    chunk_id = payload.get("chunk_id")
    if isinstance(chunk_id, str) and chunk_id.strip():
        return chunk_id.strip()
    if doc_id:
        return f"{doc_id}#0"
    return fallback_id


def normalize_dense_hit(raw_hit: dict, rank: int) -> dict:
    raw_payload = raw_hit.get("payload")
    payload = raw_payload if isinstance(raw_payload, dict) else {}
    hit_id = str(raw_hit.get("id", f"dense-{rank}"))
    doc_id = extract_doc_id(payload, hit_id)
    chunk_id = extract_chunk_id(payload, doc_id, hit_id)
    text = extract_payload_text(payload)
    source_path = payload.get("source_path") or payload.get("path") or payload.get("file_path") or doc_id
    return {
        "rank": rank,
        "id": hit_id,
        "doc_id": doc_id,
        "chunk_id": chunk_id,
        "score": float(raw_hit.get("score", 0.0) or 0.0),
        "source_path": str(source_path),
        "text_excerpt": text[:400],
        "payload": payload,
    }


def normalize_lexical_hit(raw_hit: dict, rank: int) -> dict:
    source = raw_hit.get("_source")
    payload = source if isinstance(source, dict) else {}
    hit_id = str(raw_hit.get("_id", f"lexical-{rank}"))
    doc_id = extract_doc_id(payload, hit_id)
    chunk_id = extract_chunk_id(payload, doc_id, hit_id)
    text = extract_payload_text(payload)
    source_path = payload.get("source_path") or payload.get("path") or payload.get("file_path") or doc_id
    return {
        "rank": rank,
        "id": hit_id,
        "doc_id": doc_id,
        "chunk_id": chunk_id,
        "score": float(raw_hit.get("_score", 0.0) or 0.0),
        "source_path": str(source_path),
        "text_excerpt": text[:400],
        "payload": payload,
    }


def embed_query(query: str) -> list[float]:
    headers = {"X-Agent-Session": "rag-retriever", "X-Agent-Project": "rag"}
    if GATE_DRY_RUN:
        headers["X-Gate-Dry-Run"] = "1"

    try:
        response = request_json(
            f"{GATE_URL}/v1/embeddings",
            payload={"model": EMBED_MODEL, "input": query},
            headers=headers,
        )
        data = response.get("data")
        if not isinstance(data, list) or not data:
            raise RuntimeError("missing embedding data in gate response")
        first = data[0]
        if not isinstance(first, dict):
            raise RuntimeError("invalid embedding item in gate response")
        embedding = first.get("embedding")
        if not isinstance(embedding, list) or not embedding:
            raise RuntimeError("missing embedding vector in gate response")

        return [float(value) for value in embedding]
    except Exception as exc:
        if GATE_DRY_RUN:
            return deterministic_dry_run_embedding(query)
        raise RuntimeError(f"embedding request failed: {exc}") from exc


def retrieve_dense(query: str, top_k: int) -> dict:
    result: dict[str, object] = {
        "backend": DENSE_BACKEND,
        "status": "disabled",
        "hits": [],
    }

    if DENSE_BACKEND != "qdrant":
        return result

    try:
        vector = embed_query(query)
        expected_size = collection_vector_size()
        if expected_size is not None and expected_size != len(vector):
            if GATE_DRY_RUN:
                vector = deterministic_dry_run_embedding(query, vector_size=expected_size)
            else:
                raise RuntimeError(
                    f"query vector size mismatch (expected={expected_size}, got={len(vector)}) for collection '{COLLECTION}'"
                )
        search = request_json(
            f"{QDRANT_URL}/collections/{COLLECTION}/points/search",
            payload={
                "vector": vector,
                "limit": top_k,
                "with_payload": True,
            },
        )
    except Exception as exc:
        result["status"] = "error"
        result["error"] = str(exc)
        return result

    raw_hits = search.get("result")
    if not isinstance(raw_hits, list):
        raw_hits = []

    hits = [normalize_dense_hit(raw, rank + 1) for rank, raw in enumerate(raw_hits[:top_k])]
    result["status"] = "ok"
    result["hits"] = hits
    return result


def retrieve_lexical(query: str, top_k: int) -> dict:
    result: dict[str, object] = {
        "backend": LEXICAL_BACKEND,
        "status": "disabled",
        "hits": [],
    }

    if LEXICAL_BACKEND != "opensearch":
        return result

    try:
        payload = {
            "size": top_k,
            "track_total_hits": True,
            "query": {
                "multi_match": {
                    "query": query,
                    "fields": ["text^3", "title^2", "section", "source_path", "doc_id", "chunk_id"],
                    "type": "best_fields",
                }
            },
        }
        response = request_json(f"{OPENSEARCH_URL}/{LEXICAL_INDEX}/_search", payload=payload)
    except Exception as exc:
        result["status"] = "error"
        result["error"] = str(exc)
        return result

    raw_hits = response.get("hits", {}).get("hits", [])
    if not isinstance(raw_hits, list):
        raw_hits = []

    hits = [normalize_lexical_hit(raw, rank + 1) for rank, raw in enumerate(raw_hits[:top_k])]
    result["status"] = "ok"
    result["hits"] = hits
    return result


def fuse_rrf(dense_hits: list[dict], lexical_hits: list[dict], top_k: int) -> list[dict]:
    by_key: dict[str, dict] = {}

    def apply_rrf(hits: list[dict], source: str) -> None:
        for idx, hit in enumerate(hits, start=1):
            key = str(hit.get("chunk_id") or hit.get("doc_id") or hit.get("id") or f"{source}-{idx}")
            entry = by_key.setdefault(
                key,
                {
                    "id": key,
                    "doc_id": hit.get("doc_id", ""),
                    "chunk_id": hit.get("chunk_id", ""),
                    "source_path": hit.get("source_path", ""),
                    "text_excerpt": hit.get("text_excerpt", ""),
                    "rrf_score": 0.0,
                    "dense_score": None,
                    "lexical_score": None,
                    "sources": [],
                },
            )
            entry["rrf_score"] += 1.0 / float(RRF_K + idx)
            if source == "dense":
                entry["dense_score"] = hit.get("score")
            if source == "lexical":
                entry["lexical_score"] = hit.get("score")
            if source not in entry["sources"]:
                entry["sources"].append(source)

    apply_rrf(dense_hits, "dense")
    apply_rrf(lexical_hits, "lexical")

    fused = sorted(by_key.values(), key=lambda item: float(item.get("rrf_score", 0.0)), reverse=True)
    for rank, entry in enumerate(fused[:top_k], start=1):
        entry["rank"] = rank
    return fused[:top_k]


def backend_up(url: str, path: str = "/healthz") -> bool:
    try:
        request_json(f"{url.rstrip('/')}{path}", timeout=3)
        return True
    except Exception:
        return False


class Handler(BaseHTTPRequestHandler):
    server_version = "agentic-rag-retriever/1.0"

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return {}
        return payload if isinstance(payload, dict) else {}

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            qdrant_ok = backend_up(QDRANT_URL, "/healthz")
            gate_ok = backend_up(GATE_URL, "/healthz")
            opensearch_ok = True
            if LEXICAL_BACKEND == "opensearch":
                opensearch_ok = backend_up(OPENSEARCH_URL, "/_cluster/health")

            overall = "ok" if qdrant_ok else "degraded"
            payload = {
                "service": "rag-retriever",
                "status": overall,
                "dense_backend": DENSE_BACKEND,
                "lexical_backend": LEXICAL_BACKEND,
                "fusion_method": FUSION_METHOD,
                "qdrant_status": "up" if qdrant_ok else "down",
                "gate_status": "up" if gate_ok else "down",
                "opensearch_status": "up" if opensearch_ok else "down",
                "schema_status": SCHEMA_INFO.get("status", "unknown"),
                "ts": utc_now(),
            }
            write_state("health", json.dumps(payload, ensure_ascii=True))
            self._json(200, payload)
            return

        if self.path == "/v1/schema":
            self._json(200, SCHEMA_INFO)
            return

        if self.path == "/v1/config":
            self._json(
                200,
                {
                    "collection": COLLECTION,
                    "lexical_index": LEXICAL_INDEX,
                    "dense_backend": DENSE_BACKEND,
                    "lexical_backend": LEXICAL_BACKEND,
                    "fusion_method": FUSION_METHOD,
                    "rrf_k": RRF_K,
                    "embed_model": EMBED_MODEL,
                    "gate_dry_run": GATE_DRY_RUN,
                },
            )
            return

        self._json(404, {"error": "not_found", "path": self.path})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/retrieve":
            self._json(404, {"error": "not_found", "path": self.path})
            return

        payload = self._read_json()
        query = str(payload.get("query", "")).strip()
        if not query:
            self._json(400, {"error": "query_required"})
            return

        try:
            top_k_raw = int(payload.get("top_k", 8) or 8)
        except Exception:
            top_k_raw = 8
        top_k = max(1, min(top_k_raw, TOP_K_MAX))

        request_id = str(payload.get("request_id") or f"req-{int(datetime.now().timestamp() * 1000)}")

        dense = retrieve_dense(query, top_k)
        lexical = retrieve_lexical(query, top_k)

        dense_hits = dense.get("hits") if isinstance(dense.get("hits"), list) else []
        lexical_hits = lexical.get("hits") if isinstance(lexical.get("hits"), list) else []

        if FUSION_METHOD == "rrf":
            fused = fuse_rrf(dense_hits, lexical_hits, top_k)
        else:
            fused = dense_hits[:top_k]

        response_status = "ok"
        if not fused:
            if dense.get("status") == "error" and lexical.get("status") == "error":
                response_status = "degraded"
            elif dense.get("status") == "error":
                response_status = "partial"
            else:
                response_status = "empty"

        result = {
            "request_id": request_id,
            "status": response_status,
            "query": query,
            "top_k": top_k,
            "dense": dense,
            "lexical": lexical,
            "fusion": {"method": FUSION_METHOD, "rrf_k": RRF_K, "results": fused},
            "rerank": {"enabled": False, "results": []},
            "ts": utc_now(),
        }

        append_audit(
            {
                "ts": result["ts"],
                "request_id": request_id,
                "query_len": len(query),
                "top_k": top_k,
                "status": response_status,
                "dense_status": dense.get("status"),
                "dense_hits": len(dense_hits),
                "lexical_status": lexical.get("status"),
                "lexical_hits": len(lexical_hits),
                "fusion_hits": len(fused),
                "dense_backend": DENSE_BACKEND,
                "lexical_backend": LEXICAL_BACKEND,
                "fusion_method": FUSION_METHOD,
            }
        )
        write_state("last_request", json.dumps({"request_id": request_id, "status": response_status, "ts": result["ts"]}))
        self._json(200, result)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        return


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    write_state("heartbeat", utc_now())
    with ThreadingHTTPServer((HOST, PORT), Handler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
