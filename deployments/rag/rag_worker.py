#!/usr/bin/env python3
"""Async retrieval/index worker for Step J4."""

from __future__ import annotations

import hashlib
import json
import os
import queue
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


HOST = os.environ.get("RAG_WORKER_HOST", "0.0.0.0")
PORT = int(os.environ.get("RAG_WORKER_PORT", "7112"))
STATE_DIR = Path(os.environ.get("RAG_WORKER_STATE_DIR", "/state"))
LOG_DIR = Path(os.environ.get("RAG_WORKER_LOG_DIR", "/logs"))
RETRIEVER_URL = os.environ.get("RAG_RETRIEVER_URL", "http://rag-retriever:7111").rstrip("/")
QDRANT_URL = os.environ.get("RAG_QDRANT_URL", "http://qdrant:6333").rstrip("/")
GATE_URL = os.environ.get("RAG_GATE_URL", "http://ollama-gate:11435").rstrip("/")
OPENSEARCH_URL = os.environ.get("RAG_OPENSEARCH_URL", "http://opensearch:9200").rstrip("/")
DEFAULT_DOCS_DIR = os.environ.get("RAG_WORKER_DOCS_DIR", "/docs")
COLLECTION = os.environ.get("RAG_COLLECTION", "agentic_docs")
LEXICAL_INDEX = os.environ.get("RAG_LEXICAL_INDEX", COLLECTION)
LEXICAL_BACKEND = os.environ.get("RAG_LEXICAL_BACKEND", "disabled")
EMBED_MODEL = os.environ.get("RAG_EMBED_MODEL", "qwen3-embedding:0.6b")
POLL_INTERVAL_SEC = float(os.environ.get("RAG_WORKER_POLL_INTERVAL_SEC", "10"))
TASK_WAIT_TIMEOUT_SEC = float(os.environ.get("RAG_WORKER_SYNC_TIMEOUT_SEC", "120"))
REQUEST_TIMEOUT_SEC = float(os.environ.get("RAG_HTTP_TIMEOUT_SEC", "12"))


def is_truthy(value: str | None) -> bool:
    if value is None:
        return False
    return value.strip().lower() in {"1", "true", "yes", "on"}


GATE_DRY_RUN = is_truthy(os.environ.get("RAG_GATE_DRY_RUN", "1"))
BOOTSTRAP_INDEX = is_truthy(os.environ.get("RAG_WORKER_BOOTSTRAP_INDEX", "1"))

TASK_QUEUE: queue.Queue[str] = queue.Queue()
TASKS: dict[str, dict] = {}
TASKS_LOCK = threading.Lock()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def write_state(name: str, value: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / name).write_text(value + "\n", encoding="utf-8")


def append_log(event: dict) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with (LOG_DIR / "worker.audit.jsonl").open("a", encoding="utf-8") as handle:
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

    req_method = method
    body = None
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


def collection_exists(collection: str) -> bool:
    request = urllib.request.Request(f"{QDRANT_URL}/collections/{collection}", method="GET")
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SEC):
            return True
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return False
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} while checking qdrant collection: {detail[:400]}") from exc
    except Exception as exc:
        raise RuntimeError(f"cannot check qdrant collection: {exc}") from exc


def ensure_collection(vector_size: int) -> None:
    if collection_exists(COLLECTION):
        return
    request_json(
        f"{QDRANT_URL}/collections/{COLLECTION}",
        payload={
            "vectors": {
                "size": vector_size,
                "distance": "Cosine",
                "on_disk": False,
            }
        },
        method="PUT",
    )


def embed_text(text: str) -> list[float]:
    headers = {"X-Agent-Session": "rag-worker", "X-Agent-Project": "rag"}
    if GATE_DRY_RUN:
        headers["X-Gate-Dry-Run"] = "1"

    response = request_json(
        f"{GATE_URL}/v1/embeddings",
        payload={"model": EMBED_MODEL, "input": text},
        headers=headers,
    )
    data = response.get("data")
    if not isinstance(data, list) or not data or not isinstance(data[0], dict):
        raise RuntimeError("invalid embedding response from gate")
    vector = data[0].get("embedding")
    if not isinstance(vector, list) or not vector:
        raise RuntimeError("missing embedding vector from gate")

    try:
        return [float(value) for value in vector]
    except Exception as exc:
        raise RuntimeError(f"non-numeric embedding values: {exc}") from exc


def stable_point_id(doc_key: str, text: str) -> int:
    digest = hashlib.sha256(f"{doc_key}\n{text}".encode("utf-8")).hexdigest()[:16]
    return int(digest, 16)


def build_payload(path: Path, text: str) -> dict:
    line_count = max(1, text.count("\n") + 1)
    doc_id = path.name
    return {
        "doc_id": doc_id,
        "chunk_id": f"{doc_id}#0",
        "text": text,
        "source_type": "code",
        "source_path": path.name,
        "file_path": path.name,
        "start_line": 1,
        "end_line": line_count,
        "section": path.stem,
        "title": path.stem,
        "language": "en",
        "timestamp": utc_now(),
        "version": "j4-full",
        "path": path.name,
    }


def upsert_qdrant(payload: dict, vector: list[float]) -> None:
    doc_key = str(payload.get("chunk_id") or payload.get("doc_id") or payload.get("source_path") or "doc")
    request_json(
        f"{QDRANT_URL}/collections/{COLLECTION}/points",
        payload={
            "points": [
                {
                    "id": stable_point_id(doc_key, str(payload.get("text", ""))),
                    "vector": vector,
                    "payload": payload,
                }
            ]
        },
        method="PUT",
    )


def upsert_opensearch(payload: dict) -> None:
    if LEXICAL_BACKEND != "opensearch":
        return

    doc_id = str(payload.get("chunk_id") or payload.get("doc_id") or payload.get("source_path") or "doc")
    encoded_id = urllib.parse.quote(doc_id, safe="")
    request_json(
        f"{OPENSEARCH_URL}/{LEXICAL_INDEX}/_doc/{encoded_id}",
        payload=payload,
        method="PUT",
    )


def ingest_docs(docs_dir: str) -> dict:
    path = Path(docs_dir)
    if not path.is_dir():
        raise RuntimeError(f"docs directory not found: {docs_dir}")

    doc_paths = sorted(p for p in path.glob("*.txt") if p.is_file())
    if not doc_paths:
        raise RuntimeError(f"no .txt documents found in {docs_dir}")

    indexed = 0
    lexical_indexed = 0
    vector_size = 0

    for doc_path in doc_paths:
        text = doc_path.read_text(encoding="utf-8").strip()
        if not text:
            continue
        payload = build_payload(doc_path, text)
        vector = embed_text(text)

        if indexed == 0:
            vector_size = len(vector)
            ensure_collection(vector_size)

        upsert_qdrant(payload, vector)
        indexed += 1

        if LEXICAL_BACKEND == "opensearch":
            upsert_opensearch(payload)
            lexical_indexed += 1

    if indexed == 0:
        raise RuntimeError(f"all documents are empty in {docs_dir}")

    return {
        "docs_dir": str(path),
        "collection": COLLECTION,
        "indexed": indexed,
        "lexical_backend": LEXICAL_BACKEND,
        "lexical_indexed": lexical_indexed,
        "vector_size": vector_size,
    }


def create_task(task_type: str, payload: dict) -> str:
    task_id = f"task-{int(time.time() * 1000)}-{os.getpid()}-{len(TASKS) + 1}"
    task = {
        "task_id": task_id,
        "type": task_type,
        "payload": payload,
        "status": "pending",
        "created_at": utc_now(),
        "started_at": None,
        "finished_at": None,
        "result": None,
        "error": None,
    }
    with TASKS_LOCK:
        TASKS[task_id] = task
    TASK_QUEUE.put(task_id)
    append_log({"ts": utc_now(), "event": "task_enqueued", "task_id": task_id, "type": task_type})
    return task_id


def get_task(task_id: str) -> dict | None:
    with TASKS_LOCK:
        task = TASKS.get(task_id)
        if task is None:
            return None
        return dict(task)


def update_task(task_id: str, **changes: object) -> None:
    with TASKS_LOCK:
        task = TASKS.get(task_id)
        if task is None:
            return
        task.update(changes)


def run_task_loop() -> None:
    while True:
        task_id = TASK_QUEUE.get()
        task = get_task(task_id)
        if task is None:
            TASK_QUEUE.task_done()
            continue

        update_task(task_id, status="running", started_at=utc_now())
        write_state("last_task", json.dumps({"task_id": task_id, "status": "running", "ts": utc_now()}, ensure_ascii=True))

        try:
            task_type = str(task.get("type") or "")
            payload = task.get("payload") if isinstance(task.get("payload"), dict) else {}

            if task_type == "index":
                docs_dir = str(payload.get("docs_dir") or DEFAULT_DOCS_DIR)
                result = ingest_docs(docs_dir)
            else:
                raise RuntimeError(f"unsupported task type: {task_type}")

            update_task(task_id, status="done", finished_at=utc_now(), result=result)
            append_log({"ts": utc_now(), "event": "task_done", "task_id": task_id, "result": result})
        except Exception as exc:
            update_task(task_id, status="error", finished_at=utc_now(), error=str(exc))
            append_log({"ts": utc_now(), "event": "task_error", "task_id": task_id, "error": str(exc)})

        task_done = get_task(task_id)
        if task_done is not None:
            write_state(
                "last_task",
                json.dumps(
                    {
                        "task_id": task_done.get("task_id"),
                        "status": task_done.get("status"),
                        "finished_at": task_done.get("finished_at"),
                    },
                    ensure_ascii=True,
                ),
            )
        TASK_QUEUE.task_done()


def poll_retriever() -> None:
    while True:
        now = utc_now()
        status = "down"
        try:
            response = request_json(f"{RETRIEVER_URL}/healthz", timeout=4)
            if response.get("status") in {"ok", "degraded"}:
                status = "up"
        except Exception:
            status = "down"

        write_state("retriever_status", status)
        write_state("heartbeat", now)
        append_log({"ts": now, "event": "retriever_probe", "retriever_url": RETRIEVER_URL, "retriever_status": status})
        time.sleep(POLL_INTERVAL_SEC)


def wait_task(task_id: str, timeout_sec: float) -> dict | None:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        task = get_task(task_id)
        if task is None:
            return None
        if task.get("status") in {"done", "error"}:
            return task
        time.sleep(0.2)
    return get_task(task_id)


class Handler(BaseHTTPRequestHandler):
    server_version = "agentic-rag-worker/1.0"

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
            status_path = STATE_DIR / "retriever_status"
            retriever_status = status_path.read_text(encoding="utf-8").strip() if status_path.is_file() else "unknown"
            payload = {
                "service": "rag-worker",
                "status": "ok",
                "mode": "full",
                "retriever_status": retriever_status,
                "queue_depth": TASK_QUEUE.qsize(),
                "tasks_total": len(TASKS),
                "ts": utc_now(),
            }
            self._json(200, payload)
            return

        if self.path.startswith("/v1/tasks/"):
            task_id = self.path.split("/v1/tasks/", 1)[1].strip()
            if not task_id:
                self._json(400, {"error": "task_id_required"})
                return
            task = get_task(task_id)
            if task is None:
                self._json(404, {"error": "task_not_found", "task_id": task_id})
                return
            self._json(200, task)
            return

        self._json(404, {"error": "not_found", "path": self.path})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/index":
            self._json(404, {"error": "not_found", "path": self.path})
            return

        payload = self._read_json()
        docs_dir = str(payload.get("docs_dir") or DEFAULT_DOCS_DIR)
        sync = bool(payload.get("sync", False))

        task_id = create_task("index", {"docs_dir": docs_dir})

        if sync:
            task = wait_task(task_id, TASK_WAIT_TIMEOUT_SEC)
            if task is None:
                self._json(500, {"error": "task_lookup_failed", "task_id": task_id})
                return
            if task.get("status") == "done":
                self._json(200, {"status": "completed", "task": task})
                return
            if task.get("status") == "error":
                self._json(500, {"status": "error", "task": task})
                return
            self._json(202, {"status": "accepted", "task": task, "note": "still running"})
            return

        self._json(202, {"status": "accepted", "task_id": task_id})

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        return


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    write_state("retriever_status", "unknown")
    write_state("heartbeat", utc_now())

    threading.Thread(target=run_task_loop, daemon=True).start()
    threading.Thread(target=poll_retriever, daemon=True).start()

    if BOOTSTRAP_INDEX:
        create_task("index", {"docs_dir": DEFAULT_DOCS_DIR})

    with ThreadingHTTPServer((HOST, PORT), Handler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
