#!/usr/bin/env python3
"""Skeleton async worker for Step J4."""

from __future__ import annotations

import json
import os
import threading
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


HOST = os.environ.get("RAG_WORKER_HOST", "0.0.0.0")
PORT = int(os.environ.get("RAG_WORKER_PORT", "7112"))
STATE_DIR = Path(os.environ.get("RAG_WORKER_STATE_DIR", "/state"))
LOG_DIR = Path(os.environ.get("RAG_WORKER_LOG_DIR", "/logs"))
RETRIEVER_URL = os.environ.get("RAG_RETRIEVER_URL", "http://rag-retriever:7111")
POLL_INTERVAL_SEC = float(os.environ.get("RAG_WORKER_POLL_INTERVAL_SEC", "10"))


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def write_state(name: str, value: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / name).write_text(value + "\n", encoding="utf-8")


def append_log(event: dict) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with (LOG_DIR / "worker.audit.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=True) + "\n")


def poll_retriever() -> None:
    while True:
        now = utc_now()
        status = "down"
        try:
            with urllib.request.urlopen(f"{RETRIEVER_URL.rstrip('/')}/healthz", timeout=3) as resp:
                if resp.status == 200:
                    status = "up"
        except Exception:
            status = "down"
        write_state("retriever_status", status)
        write_state("heartbeat", now)
        append_log({"ts": now, "retriever_url": RETRIEVER_URL, "retriever_status": status})
        time.sleep(POLL_INTERVAL_SEC)


class Handler(BaseHTTPRequestHandler):
    server_version = "agentic-rag-worker-skeleton/0.1"

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            status_path = STATE_DIR / "retriever_status"
            retriever_status = status_path.read_text(encoding="utf-8").strip() if status_path.is_file() else "unknown"
            self._json(
                200,
                {
                    "service": "rag-worker",
                    "status": "ok",
                    "mode": "skeleton",
                    "retriever_status": retriever_status,
                    "ts": utc_now(),
                },
            )
            return

        self._json(404, {"error": "not_found", "path": self.path})

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        return


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    write_state("retriever_status", "unknown")
    write_state("heartbeat", utc_now())
    thread = threading.Thread(target=poll_retriever, daemon=True)
    thread.start()
    with ThreadingHTTPServer((HOST, PORT), Handler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
