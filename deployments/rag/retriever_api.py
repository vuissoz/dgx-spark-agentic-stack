#!/usr/bin/env python3
"""Skeleton retrieval orchestrator for Step J4."""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


HOST = os.environ.get("RAG_RETRIEVER_HOST", "0.0.0.0")
PORT = int(os.environ.get("RAG_RETRIEVER_PORT", "7111"))
SCHEMA_PATH = Path(os.environ.get("RAG_SCHEMA_PATH", "/config/document.schema.json"))
STATE_DIR = Path(os.environ.get("RAG_RETRIEVER_STATE_DIR", "/state"))
LOG_DIR = Path(os.environ.get("RAG_RETRIEVER_LOG_DIR", "/logs"))
DENSE_BACKEND = os.environ.get("RAG_DENSE_BACKEND", "qdrant")
LEXICAL_BACKEND = os.environ.get("RAG_LEXICAL_BACKEND", "disabled")
FUSION_METHOD = os.environ.get("RAG_FUSION_METHOD", "rrf")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_schema() -> dict:
    if not SCHEMA_PATH.is_file():
        return {"status": "missing", "path": str(SCHEMA_PATH)}
    try:
        return {"status": "loaded", "path": str(SCHEMA_PATH), "schema": json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))}
    except Exception as exc:  # pragma: no cover - defensive skeleton
        return {"status": "error", "path": str(SCHEMA_PATH), "error": str(exc)}


SCHEMA_INFO = load_schema()


def append_audit(event: dict) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / "retrieval.audit.jsonl"
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=True) + "\n")


class Handler(BaseHTTPRequestHandler):
    server_version = "agentic-rag-retriever-skeleton/0.1"

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
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            self._json(
                200,
                {
                    "service": "rag-retriever",
                    "status": "ok",
                    "mode": "skeleton",
                    "dense_backend": DENSE_BACKEND,
                    "lexical_backend": LEXICAL_BACKEND,
                    "fusion_method": FUSION_METHOD,
                    "schema_status": SCHEMA_INFO.get("status", "unknown"),
                    "ts": utc_now(),
                },
            )
            return

        if self.path == "/v1/schema":
            self._json(200, SCHEMA_INFO)
            return

        self._json(404, {"error": "not_found", "path": self.path})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/retrieve":
            self._json(404, {"error": "not_found", "path": self.path})
            return

        payload = self._read_json()
        query = str(payload.get("query", "")).strip()
        top_k = int(payload.get("top_k", 10) or 10)
        request_id = str(payload.get("request_id") or f"req-{int(datetime.now().timestamp() * 1000)}")

        result = {
            "request_id": request_id,
            "status": "skeleton",
            "query": query,
            "top_k": top_k,
            "dense": {"backend": DENSE_BACKEND, "hits": []},
            "lexical": {"backend": LEXICAL_BACKEND, "hits": []},
            "fusion": {"method": FUSION_METHOD, "results": []},
            "rerank": {"enabled": False, "results": []},
            "notes": "J4 skeleton endpoint only; dense/lexical execution not implemented yet.",
            "ts": utc_now(),
        }
        append_audit(
            {
                "ts": result["ts"],
                "request_id": request_id,
                "query_len": len(query),
                "top_k": top_k,
                "dense_backend": DENSE_BACKEND,
                "lexical_backend": LEXICAL_BACKEND,
                "fusion_method": FUSION_METHOD,
            }
        )
        self._json(200, result)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        # Keep container stdout quiet; structured events go to audit jsonl.
        return


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    heartbeat_path = STATE_DIR / "heartbeat"
    heartbeat_path.write_text(utc_now() + "\n", encoding="utf-8")
    with ThreadingHTTPServer((HOST, PORT), Handler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
