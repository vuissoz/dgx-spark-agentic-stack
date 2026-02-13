#!/usr/bin/env python3
import asyncio
import json
import os
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Tuple

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse


def env_int(name: str, default: int) -> int:
    raw = os.getenv(name, str(default))
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def env_float(name: str, default: float) -> float:
    raw = os.getenv(name, str(default))
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


def env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def header_bool(value: str | None) -> bool:
    if value is None:
        return False
    return value.strip().lower() in ("1", "true", "yes", "on")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class GateState:
    def __init__(self) -> None:
        self.ollama_base_url = os.getenv("OLLAMA_BASE_URL", "http://ollama:11434").rstrip("/")
        self.concurrency = max(1, env_int("GATE_CONCURRENCY", 1))
        self.default_queue_wait_timeout_seconds = max(
            0.1, env_float("GATE_QUEUE_WAIT_TIMEOUT_SECONDS", 2.0)
        )
        self.enable_test_mode = env_bool("GATE_ENABLE_TEST_MODE", False)
        self.max_test_sleep_seconds = max(0, env_int("GATE_MAX_TEST_SLEEP_SECONDS", 15))
        self.log_file = Path(os.getenv("GATE_LOG_FILE", "/gate/logs/gate.jsonl"))
        self.sticky_file = Path(
            os.getenv("GATE_STICKY_FILE", os.getenv("GATE_STATE_DIR", "/gate/state") + "/sticky_sessions.json")
        )

        self.sem = asyncio.Semaphore(self.concurrency)
        self.lock = asyncio.Lock()
        self.queue_depth = 0
        self.active_requests = 0
        self.requests_total = 0
        self.decisions_total: Dict[str, int] = {"active": 0, "queued": 0, "denied": 0}
        self.sticky_models: Dict[str, str] = {}
        self._sticky_dirty = False

        self.log_file.parent.mkdir(parents=True, exist_ok=True)
        self.sticky_file.parent.mkdir(parents=True, exist_ok=True)
        self._load_sticky()

    def _load_sticky(self) -> None:
        if not self.sticky_file.exists():
            self.sticky_models = {}
            return
        try:
            raw = json.loads(self.sticky_file.read_text(encoding="utf-8"))
        except Exception:
            self.sticky_models = {}
            return
        if isinstance(raw, dict):
            self.sticky_models = {str(k): str(v) for k, v in raw.items() if isinstance(v, str)}
        else:
            self.sticky_models = {}

    def _save_sticky(self) -> None:
        tmp = self.sticky_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.sticky_models, sort_keys=True), encoding="utf-8")
        os.replace(tmp, self.sticky_file)

    async def flush_sticky_if_dirty(self) -> None:
        async with self.lock:
            if not self._sticky_dirty:
                return
            self._sticky_dirty = False
        self._save_sticky()

    async def set_sticky_model(self, session: str, model: str) -> None:
        async with self.lock:
            self.sticky_models[session] = model
            self._sticky_dirty = True
        await self.flush_sticky_if_dirty()

    async def get_sticky_model(self, session: str) -> str | None:
        async with self.lock:
            return self.sticky_models.get(session)

    async def mark_decision(self, decision: str) -> None:
        async with self.lock:
            self.requests_total += 1
            self.decisions_total[decision] = self.decisions_total.get(decision, 0) + 1

    async def queue_inc(self) -> None:
        async with self.lock:
            self.queue_depth += 1

    async def queue_dec(self) -> None:
        async with self.lock:
            self.queue_depth = max(0, self.queue_depth - 1)

    async def active_inc(self) -> None:
        async with self.lock:
            self.active_requests += 1

    async def active_dec(self) -> None:
        async with self.lock:
            self.active_requests = max(0, self.active_requests - 1)

    async def snapshot_metrics(self) -> Dict[str, int]:
        async with self.lock:
            return {
                "queue_depth": self.queue_depth,
                "active_requests": self.active_requests,
                "requests_total": self.requests_total,
                "decisions_active_total": self.decisions_total.get("active", 0),
                "decisions_queued_total": self.decisions_total.get("queued", 0),
                "decisions_denied_total": self.decisions_total.get("denied", 0),
            }

    def write_log(self, event: Dict[str, Any]) -> None:
        line = json.dumps(event, ensure_ascii=True, separators=(",", ":"))
        print(line, flush=True)
        with self.log_file.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")


state = GateState()
app = FastAPI(title="ollama-gate", version="0.1.0")


async def fetch_ollama_models() -> list[str]:
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{state.ollama_base_url}/api/tags")
        resp.raise_for_status()
        payload = resp.json()
    models = payload.get("models", [])
    names: list[str] = []
    if isinstance(models, list):
        for item in models:
            if isinstance(item, dict):
                name = item.get("name")
                if isinstance(name, str) and name:
                    names.append(name)
    return names


async def resolve_model(session: str, requested: str | None, allow_switch: bool) -> Tuple[str, bool]:
    existing = await state.get_sticky_model(session)
    model_switch = False
    if existing:
        if requested and requested != existing:
            if allow_switch:
                await state.set_sticky_model(session, requested)
                return requested, True
            return existing, False
        return existing, False

    chosen = requested
    if not chosen:
        models = await fetch_ollama_models()
        chosen = models[0] if models else "unknown"
    await state.set_sticky_model(session, chosen)
    return chosen, False


def extract_queue_timeout_seconds(request: Request) -> float:
    raw = request.headers.get("X-Gate-Queue-Timeout-Seconds")
    if not raw:
        return state.default_queue_wait_timeout_seconds
    try:
        value = float(raw)
    except ValueError:
        return state.default_queue_wait_timeout_seconds
    return max(0.1, value)


def extract_test_sleep_seconds(request: Request) -> int:
    raw = request.headers.get("X-Gate-Test-Sleep", "0")
    try:
        value = int(raw)
    except ValueError:
        return 0
    return max(0, min(value, state.max_test_sleep_seconds))


async def acquire_gate_slot(queue_wait_timeout_seconds: float) -> Tuple[str, bool]:
    queued = state.sem.locked()
    if queued:
        await state.queue_inc()
    try:
        await asyncio.wait_for(state.sem.acquire(), timeout=queue_wait_timeout_seconds)
    except asyncio.TimeoutError:
        if queued:
            await state.queue_dec()
        raise
    if queued:
        await state.queue_dec()
    await state.active_inc()
    return ("queued" if queued else "active"), True


async def release_gate_slot(acquired: bool) -> None:
    if not acquired:
        return
    state.sem.release()
    await state.active_dec()


def event_base(
    session: str,
    project: str,
    endpoint: str,
    decision: str,
    model_requested: str | None,
    model_served: str | None,
    status_code: int,
    latency_ms: int,
    model_switch: bool = False,
    reason: str | None = None,
) -> Dict[str, Any]:
    return {
        "ts": now_iso(),
        "session": session,
        "project": project,
        "endpoint": endpoint,
        "decision": decision,
        "latency_ms": latency_ms,
        "model_requested": model_requested,
        "model_served": model_served,
        "model_switch": model_switch,
        "status_code": status_code,
        "reason": reason,
    }


@app.get("/healthz")
async def healthz() -> Dict[str, str]:
    return {"status": "ok"}


@app.get("/metrics")
async def metrics() -> PlainTextResponse:
    m = await state.snapshot_metrics()
    lines = [
        "# TYPE queue_depth gauge",
        f"queue_depth {m['queue_depth']}",
        "# TYPE gate_active_requests gauge",
        f"gate_active_requests {m['active_requests']}",
        "# TYPE gate_requests_total counter",
        f"gate_requests_total {m['requests_total']}",
        "# TYPE gate_decision_active_total counter",
        f"gate_decision_active_total {m['decisions_active_total']}",
        "# TYPE gate_decision_queued_total counter",
        f"gate_decision_queued_total {m['decisions_queued_total']}",
        "# TYPE gate_decision_denied_total counter",
        f"gate_decision_denied_total {m['decisions_denied_total']}",
    ]
    return PlainTextResponse("\n".join(lines) + "\n")


@app.get("/v1/models")
async def v1_models(request: Request) -> JSONResponse:
    queue_wait_timeout_seconds = extract_queue_timeout_seconds(request)
    session = request.headers.get("X-Agent-Session", "models-list")
    project = request.headers.get("X-Agent-Project", "-")
    started = time.monotonic()
    acquired = False
    decision = "active"
    try:
        decision, acquired = await acquire_gate_slot(queue_wait_timeout_seconds)
    except asyncio.TimeoutError:
        latency_ms = int((time.monotonic() - started) * 1000)
        await state.mark_decision("denied")
        state.write_log(
            event_base(
                session=session,
                project=project,
                endpoint="/v1/models",
                decision="denied",
                model_requested=None,
                model_served=None,
                status_code=429,
                latency_ms=latency_ms,
                reason="queue_timeout",
            )
        )
        return JSONResponse(
            status_code=429,
            content={"error": {"message": "queue timeout", "type": "queue_timeout", "decision": "denied"}},
        )

    status_code = 200
    try:
        names = await fetch_ollama_models()
        response = {
            "object": "list",
            "data": [{"id": name, "object": "model", "owned_by": "ollama-gate"} for name in names],
        }
        return JSONResponse(status_code=200, content=response, headers={"X-Gate-Decision": decision})
    except Exception as exc:
        status_code = 502
        return JSONResponse(status_code=502, content={"error": {"message": str(exc), "type": "upstream_error"}})
    finally:
        await release_gate_slot(acquired)
        await state.mark_decision("denied" if status_code == 429 else decision)
        latency_ms = int((time.monotonic() - started) * 1000)
        state.write_log(
            event_base(
                session=session,
                project=project,
                endpoint="/v1/models",
                decision="denied" if status_code == 429 else decision,
                model_requested=None,
                model_served=None,
                status_code=status_code,
                latency_ms=latency_ms,
            )
        )


@app.post("/v1/chat/completions")
async def v1_chat_completions(request: Request) -> JSONResponse:
    payload = await request.json()
    requested_model = payload.get("model")
    session = request.headers.get("X-Agent-Session") or payload.get("user") or "anonymous"
    project = request.headers.get("X-Agent-Project", "-")
    allow_switch = header_bool(request.headers.get("X-Model-Switch"))
    queue_wait_timeout_seconds = extract_queue_timeout_seconds(request)
    started = time.monotonic()
    acquired = False
    decision = "active"
    try:
        decision, acquired = await acquire_gate_slot(queue_wait_timeout_seconds)
    except asyncio.TimeoutError:
        latency_ms = int((time.monotonic() - started) * 1000)
        await state.mark_decision("denied")
        state.write_log(
            event_base(
                session=session,
                project=project,
                endpoint="/v1/chat/completions",
                decision="denied",
                model_requested=requested_model,
                model_served=None,
                status_code=429,
                latency_ms=latency_ms,
                reason="queue_timeout",
            )
        )
        return JSONResponse(
            status_code=429,
            content={
                "error": {
                    "message": "request denied by gate queue timeout",
                    "type": "queue_timeout",
                    "decision": "denied",
                    "reason": "queue_timeout",
                }
            },
        )

    model_switch = False
    model_served = None
    status_code = 200
    reason = None
    try:
        model_served, model_switch = await resolve_model(
            session=session,
            requested=requested_model if isinstance(requested_model, str) else None,
            allow_switch=allow_switch,
        )

        use_dry_run = state.enable_test_mode and header_bool(request.headers.get("X-Gate-Dry-Run"))
        if use_dry_run:
            sleep_seconds = extract_test_sleep_seconds(request)
            if sleep_seconds > 0:
                await asyncio.sleep(sleep_seconds)
            content = f"gate dry-run response for session={session} model={model_served}"
        else:
            upstream_payload = {
                "model": model_served,
                "messages": payload.get("messages", []),
                "stream": False,
            }
            async with httpx.AsyncClient(timeout=60) as client:
                upstream = await client.post(
                    f"{state.ollama_base_url}/api/chat",
                    json=upstream_payload,
                )
            if upstream.status_code >= 400:
                status_code = upstream.status_code
                reason = "upstream_error"
                return JSONResponse(
                    status_code=upstream.status_code,
                    content={"error": {"message": upstream.text, "type": "upstream_error"}},
                )
            upstream_json = upstream.json()
            content = (
                (upstream_json.get("message") or {}).get("content")
                if isinstance(upstream_json.get("message"), dict)
                else ""
            )
            if not isinstance(content, str):
                content = ""

        response_payload = {
            "id": f"chatcmpl-{uuid.uuid4().hex}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model_served,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": content},
                    "finish_reason": "stop",
                }
            ],
        }
        return JSONResponse(
            status_code=200,
            content=response_payload,
            headers={
                "X-Gate-Decision": decision,
                "X-Model-Served": model_served,
            },
        )
    finally:
        await release_gate_slot(acquired)
        await state.mark_decision("denied" if status_code == 429 else decision)
        latency_ms = int((time.monotonic() - started) * 1000)
        state.write_log(
            event_base(
                session=session,
                project=project,
                endpoint="/v1/chat/completions",
                decision="denied" if status_code == 429 else decision,
                model_requested=requested_model if isinstance(requested_model, str) else None,
                model_served=model_served,
                status_code=status_code,
                latency_ms=latency_ms,
                model_switch=model_switch,
                reason=reason,
            )
        )


@app.post("/admin/sessions/{session_id}/switch")
async def admin_switch(session_id: str, request: Request) -> JSONResponse:
    payload = await request.json()
    model = payload.get("model")
    if not isinstance(model, str) or not model:
        return JSONResponse(status_code=400, content={"error": "model is required"})
    await state.set_sticky_model(session_id, model)
    state.write_log(
        event_base(
            session=session_id,
            project=request.headers.get("X-Agent-Project", "-"),
            endpoint="/admin/sessions/switch",
            decision="admin_switch",
            model_requested=model,
            model_served=model,
            status_code=200,
            latency_ms=0,
            model_switch=True,
        )
    )
    return JSONResponse(status_code=200, content={"ok": True, "session": session_id, "model": model})


@app.get("/admin/sessions/{session_id}")
async def admin_session(session_id: str) -> JSONResponse:
    model = await state.get_sticky_model(session_id)
    return JSONResponse(status_code=200, content={"session": session_id, "model": model})
