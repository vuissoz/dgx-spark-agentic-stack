#!/usr/bin/env python3
import asyncio
import fnmatch
import hashlib
import json
import os
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Tuple

import httpx
import yaml
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


def deterministic_embedding_vector(text: str, size: int = 32) -> list[float]:
    seed = text.encode("utf-8")
    values: list[float] = []
    counter = 0
    while len(values) < size:
        digest = hashlib.sha256(seed + counter.to_bytes(4, "big")).digest()
        counter += 1
        for idx in range(0, len(digest), 4):
            chunk = int.from_bytes(digest[idx : idx + 4], "big", signed=False)
            values.append((chunk / 2147483647.5) - 1.0)
            if len(values) >= size:
                break
    return values


class BackendAuthError(RuntimeError):
    pass


class GateState:
    def __init__(self) -> None:
        self.ollama_base_url = os.getenv("OLLAMA_BASE_URL", "http://ollama:11434").rstrip("/")
        self.trtllm_base_url = os.getenv("TRTLLM_BASE_URL", "http://trtllm:11436").rstrip("/")
        self.model_routes_file = Path(os.getenv("GATE_MODEL_ROUTES_FILE", "/gate/config/model_routes.yml"))
        self.openai_api_key_file = os.getenv("GATE_OPENAI_API_KEY_FILE", "/gate/secrets/openai.api_key")
        self.openrouter_api_key_file = os.getenv(
            "GATE_OPENROUTER_API_KEY_FILE", "/gate/secrets/openrouter.api_key"
        )

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

        self.default_backend = "ollama"
        self.backends: Dict[str, Dict[str, Any]] = {}
        self.model_routes: list[Tuple[str, str]] = []

        self.log_file.parent.mkdir(parents=True, exist_ok=True)
        self.sticky_file.parent.mkdir(parents=True, exist_ok=True)

        self._load_sticky()
        self._load_model_routes()

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

    def _load_model_routes(self) -> None:
        backends: Dict[str, Dict[str, Any]] = {
            "ollama": {"protocol": "ollama", "provider": "local", "base_url": self.ollama_base_url},
            "trtllm": {"protocol": "ollama", "provider": "local", "base_url": self.trtllm_base_url},
            "openai": {
                "protocol": "openai",
                "provider": "openai",
                "base_url": "https://api.openai.com/v1",
                "api_key_file": self.openai_api_key_file,
            },
            "openrouter": {
                "protocol": "openai",
                "provider": "openrouter",
                "base_url": "https://openrouter.ai/api/v1",
                "api_key_file": self.openrouter_api_key_file,
            },
        }
        default_backend = "ollama"
        model_routes: list[Tuple[str, str]] = []

        raw: Any = {}
        if self.model_routes_file.exists():
            try:
                loaded = yaml.safe_load(self.model_routes_file.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    raw = loaded
            except Exception:
                raw = {}

        defaults = raw.get("defaults") if isinstance(raw, dict) else None
        if isinstance(defaults, dict):
            configured_default = defaults.get("backend")
            if isinstance(configured_default, str) and configured_default.strip():
                default_backend = configured_default.strip()

        configured_backends = raw.get("backends") if isinstance(raw, dict) else None
        if isinstance(configured_backends, dict):
            for backend_name, backend_cfg in configured_backends.items():
                if not isinstance(backend_name, str) or not backend_name:
                    continue
                if not isinstance(backend_cfg, dict):
                    continue

                merged = dict(backends.get(backend_name, {}))
                for field in ("base_url", "protocol", "provider", "api_key_file", "api_key_env"):
                    value = backend_cfg.get(field)
                    if isinstance(value, str) and value.strip():
                        if field == "base_url":
                            merged[field] = value.strip().rstrip("/")
                        else:
                            merged[field] = value.strip()

                extra_headers = backend_cfg.get("extra_headers")
                if isinstance(extra_headers, dict):
                    sanitized_headers: Dict[str, str] = {}
                    for key, value in extra_headers.items():
                        if isinstance(key, str) and key.strip() and isinstance(value, str):
                            sanitized_headers[key.strip()] = value.strip()
                    if sanitized_headers:
                        merged["extra_headers"] = sanitized_headers

                if "base_url" in merged and "protocol" in merged:
                    backends[backend_name] = merged

        configured_routes = raw.get("routes") if isinstance(raw, dict) else None
        if isinstance(configured_routes, list):
            for route in configured_routes:
                if not isinstance(route, dict):
                    continue
                backend = route.get("backend")
                if not isinstance(backend, str) or not backend.strip():
                    continue

                match = route.get("match")
                patterns: list[str] = []
                if isinstance(match, str) and match.strip():
                    patterns.append(match.strip())
                elif isinstance(match, list):
                    for item in match:
                        if isinstance(item, str) and item.strip():
                            patterns.append(item.strip())

                for pattern in patterns:
                    model_routes.append((pattern, backend.strip()))

        if default_backend not in backends:
            default_backend = "ollama"

        self.default_backend = default_backend
        self.backends = backends
        self.model_routes = model_routes

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

    def resolve_backend(self, model_name: str | None) -> str:
        if not isinstance(model_name, str) or not model_name:
            return self.default_backend

        lowered = model_name.lower()
        for pattern, backend in self.model_routes:
            if fnmatch.fnmatch(lowered, pattern.lower()):
                return backend

        return self.default_backend

    def backend_config(self, backend_name: str) -> Dict[str, Any] | None:
        cfg = self.backends.get(backend_name)
        if not isinstance(cfg, dict):
            return None

        base_url = cfg.get("base_url")
        protocol = cfg.get("protocol")
        if not isinstance(base_url, str) or not base_url:
            return None
        if not isinstance(protocol, str) or not protocol:
            return None

        normalized: Dict[str, Any] = {
            "base_url": base_url.rstrip("/"),
            "protocol": protocol.strip().lower(),
        }

        provider = cfg.get("provider")
        if isinstance(provider, str) and provider.strip():
            normalized["provider"] = provider.strip().lower()
        elif normalized["protocol"] == "ollama":
            normalized["provider"] = "local"
        else:
            normalized["provider"] = backend_name

        api_key_file = cfg.get("api_key_file")
        if isinstance(api_key_file, str) and api_key_file.strip():
            normalized["api_key_file"] = api_key_file.strip()

        api_key_env = cfg.get("api_key_env")
        if isinstance(api_key_env, str) and api_key_env.strip():
            normalized["api_key_env"] = api_key_env.strip()

        extra_headers = cfg.get("extra_headers")
        if isinstance(extra_headers, dict):
            sanitized_headers: Dict[str, str] = {}
            for key, value in extra_headers.items():
                if isinstance(key, str) and key.strip() and isinstance(value, str):
                    sanitized_headers[key.strip()] = value.strip()
            if sanitized_headers:
                normalized["extra_headers"] = sanitized_headers

        return normalized

    def backend_provider(self, backend_name: str) -> str | None:
        cfg = self.backend_config(backend_name)
        if cfg is None:
            return None
        provider = cfg.get("provider")
        if isinstance(provider, str) and provider:
            return provider
        return None

    def write_log(self, event: Dict[str, Any]) -> None:
        line = json.dumps(event, ensure_ascii=True, separators=(",", ":"))
        print(line, flush=True)
        with self.log_file.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")


state = GateState()
app = FastAPI(title="ollama-gate", version="0.2.0")


def backend_unavailable_response(backend: str, model: str, detail: str) -> JSONResponse:
    provider = backend_provider_name(backend)
    message = (
        f"backend '{backend}' is unavailable for routed model '{model}'. "
        "Enable COMPOSE_PROFILES=trt and verify 'trtllm' health before retrying."
        if backend == "trtllm"
        else (
            f"backend '{backend}' is unavailable for routed model '{model}'. "
            "Verify proxy allowlist and provider endpoint reachability."
            if provider in ("openai", "openrouter")
            else f"backend '{backend}' is unavailable for routed model '{model}'."
        )
    )
    return JSONResponse(
        status_code=503,
        content={
            "error": {
                "message": message,
                "type": "backend_unavailable",
                "backend": backend,
                "provider": provider,
                "model": model,
                "detail": detail,
            }
        },
    )


def backend_auth_response(backend: str, provider: str | None, detail: str) -> JSONResponse:
    return JSONResponse(
        status_code=503,
        content={
            "error": {
                "message": detail,
                "type": "backend_auth_error",
                "backend": backend,
                "provider": provider,
            }
        },
    )


def read_secret_file(secret_path: str) -> str | None:
    path = Path(secret_path)
    if not path.exists() or not path.is_file():
        return None
    try:
        value = path.read_text(encoding="utf-8").strip()
    except Exception:
        return None
    if not value:
        return None
    return value


def backend_provider_name(backend: str) -> str:
    provider = state.backend_provider(backend)
    if isinstance(provider, str) and provider:
        return provider
    return backend


def resolve_backend_api_key(backend: str, cfg: Dict[str, Any]) -> str:
    env_key_name = cfg.get("api_key_env")
    if isinstance(env_key_name, str) and env_key_name:
        env_value = os.getenv(env_key_name, "").strip()
        if env_value:
            return env_value

    api_key_file = cfg.get("api_key_file")
    if isinstance(api_key_file, str) and api_key_file:
        file_value = read_secret_file(api_key_file)
        if file_value:
            return file_value
        raise BackendAuthError(
            f"missing API key for backend '{backend}': create non-empty file {api_key_file} (mode 600)"
        )

    raise BackendAuthError(
        f"missing API key for backend '{backend}': configure 'api_key_env' or 'api_key_file' in model_routes.yml"
    )


def backend_request_headers(cfg: Dict[str, Any], api_key: str) -> Dict[str, str]:
    headers: Dict[str, str] = {"Authorization": f"Bearer {api_key}"}

    extra_headers = cfg.get("extra_headers")
    if isinstance(extra_headers, dict):
        for key, value in extra_headers.items():
            if isinstance(key, str) and key.strip() and isinstance(value, str):
                headers[key.strip()] = value.strip()

    provider = cfg.get("provider")
    if provider == "openrouter":
        headers.setdefault("HTTP-Referer", "https://localhost/agentic")
        headers.setdefault("X-Title", "DGX Spark Agentic Stack")

    return headers


async def fetch_backend_models(backend: str) -> list[str]:
    cfg = state.backend_config(backend)
    if cfg is None:
        return []

    if cfg["protocol"] == "ollama":
        async with httpx.AsyncClient(timeout=10, trust_env=True) as client:
            resp = await client.get(f"{cfg['base_url']}/api/tags")
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

    if cfg["protocol"] == "openai":
        api_key = resolve_backend_api_key(backend, cfg)
        headers = backend_request_headers(cfg, api_key)
        async with httpx.AsyncClient(timeout=15, trust_env=True) as client:
            resp = await client.get(f"{cfg['base_url']}/models", headers=headers)
            resp.raise_for_status()
            payload = resp.json()

        names: list[str] = []
        models = payload.get("data")
        if isinstance(models, list):
            for item in models:
                if not isinstance(item, dict):
                    continue
                name = item.get("id")
                if isinstance(name, str) and name:
                    names.append(name)
        return names

    return []


async def resolve_model(session: str, requested: str | None, allow_switch: bool) -> Tuple[str, bool]:
    existing = await state.get_sticky_model(session)
    if existing:
        if requested and requested != existing:
            if allow_switch:
                await state.set_sticky_model(session, requested)
                return requested, True
            return existing, False
        return existing, False

    chosen = requested
    if not chosen:
        models = await fetch_backend_models(state.default_backend)
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
    backend: str | None = None,
    provider: str | None = None,
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
        "backend": backend,
        "provider": provider,
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
    backend = state.default_backend
    provider = backend_provider_name(backend)
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
                backend=backend,
                provider=provider,
                reason="queue_timeout",
            )
        )
        return JSONResponse(
            status_code=429,
            content={"error": {"message": "queue timeout", "type": "queue_timeout", "decision": "denied"}},
        )

    status_code = 200
    try:
        provider = backend_provider_name(backend)
        names = await fetch_backend_models(backend)
        response = {
            "object": "list",
            "data": [{"id": name, "object": "model", "owned_by": "ollama-gate"} for name in names],
        }
        return JSONResponse(
            status_code=200,
            content=response,
            headers={
                "X-Gate-Decision": decision,
                "X-Gate-Backend": backend,
                "X-Gate-Provider": provider,
            },
        )
    except BackendAuthError as exc:
        status_code = 503
        return backend_auth_response(backend, provider, str(exc))
    except Exception as exc:
        status_code = 502
        return JSONResponse(
            status_code=502,
            content={
                "error": {
                    "message": str(exc),
                    "type": "upstream_error",
                    "backend": backend,
                    "provider": provider,
                }
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
                endpoint="/v1/models",
                decision="denied" if status_code == 429 else decision,
                model_requested=None,
                model_served=None,
                status_code=status_code,
                latency_ms=latency_ms,
                backend=backend,
                provider=provider,
            )
        )


async def backend_chat_completion(backend: str, model: str, messages: Any) -> tuple[int, dict[str, Any], str]:
    cfg = state.backend_config(backend)
    if cfg is None:
        raise RuntimeError(f"backend '{backend}' is not configured")

    protocol = cfg["protocol"]

    if protocol == "ollama":
        upstream_payload = {
            "model": model,
            "messages": messages if isinstance(messages, list) else [],
            "stream": False,
        }

        try:
            async with httpx.AsyncClient(timeout=60, trust_env=True) as client:
                upstream = await client.post(f"{cfg['base_url']}/api/chat", json=upstream_payload)
        except httpx.RequestError as exc:
            raise ConnectionError(str(exc)) from exc

        text = upstream.text
        if upstream.status_code >= 400:
            return upstream.status_code, {}, text

        return upstream.status_code, upstream.json(), text

    if protocol == "openai":
        api_key = resolve_backend_api_key(backend, cfg)
        upstream_payload = {
            "model": model,
            "messages": messages if isinstance(messages, list) else [],
            "stream": False,
        }
        headers = backend_request_headers(cfg, api_key)

        try:
            async with httpx.AsyncClient(timeout=75, trust_env=True) as client:
                upstream = await client.post(
                    f"{cfg['base_url']}/chat/completions",
                    json=upstream_payload,
                    headers=headers,
                )
        except httpx.RequestError as exc:
            raise ConnectionError(str(exc)) from exc

        text = upstream.text
        if upstream.status_code >= 400:
            return upstream.status_code, {}, text

        return upstream.status_code, upstream.json(), text

    raise RuntimeError(f"unsupported backend protocol '{protocol}'")


async def backend_embedding(backend: str, model: str, prompt: str) -> tuple[int, dict[str, Any], str]:
    cfg = state.backend_config(backend)
    if cfg is None:
        raise RuntimeError(f"backend '{backend}' is not configured")

    protocol = cfg["protocol"]

    if protocol == "ollama":
        try:
            async with httpx.AsyncClient(timeout=60, trust_env=True) as client:
                upstream = await client.post(
                    f"{cfg['base_url']}/api/embeddings",
                    json={"model": model, "prompt": prompt},
                )
        except httpx.RequestError as exc:
            raise ConnectionError(str(exc)) from exc

        text = upstream.text
        if upstream.status_code >= 400:
            return upstream.status_code, {}, text

        return upstream.status_code, upstream.json(), text

    if protocol == "openai":
        api_key = resolve_backend_api_key(backend, cfg)
        headers = backend_request_headers(cfg, api_key)
        try:
            async with httpx.AsyncClient(timeout=75, trust_env=True) as client:
                upstream = await client.post(
                    f"{cfg['base_url']}/embeddings",
                    json={"model": model, "input": prompt},
                    headers=headers,
                )
        except httpx.RequestError as exc:
            raise ConnectionError(str(exc)) from exc

        text = upstream.text
        if upstream.status_code >= 400:
            return upstream.status_code, {}, text

        return upstream.status_code, upstream.json(), text

    raise RuntimeError(f"unsupported backend protocol '{protocol}'")


def chat_content_from_upstream(protocol: str, payload: Dict[str, Any]) -> str:
    if protocol == "ollama":
        message = payload.get("message")
        if isinstance(message, dict):
            content = message.get("content")
            if isinstance(content, str):
                return content
        return ""

    if protocol == "openai":
        choices = payload.get("choices")
        if not isinstance(choices, list) or not choices:
            return ""
        first = choices[0]
        if not isinstance(first, dict):
            return ""
        message = first.get("message")
        if not isinstance(message, dict):
            return ""
        content = message.get("content")
        if isinstance(content, str):
            return content
        return ""

    return ""


def embedding_from_upstream(protocol: str, payload: Dict[str, Any]) -> list[float] | None:
    if protocol == "ollama":
        embedding = payload.get("embedding")
        if isinstance(embedding, list) and embedding:
            return [float(value) for value in embedding]
        return None

    if protocol == "openai":
        data = payload.get("data")
        if not isinstance(data, list) or not data:
            return None
        first = data[0]
        if not isinstance(first, dict):
            return None
        embedding = first.get("embedding")
        if not isinstance(embedding, list) or not embedding:
            return None
        return [float(value) for value in embedding]

    return None


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
                model_requested=requested_model if isinstance(requested_model, str) else None,
                model_served=None,
                status_code=429,
                latency_ms=latency_ms,
                backend=state.default_backend,
                provider=backend_provider_name(state.default_backend),
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
    model_served: str | None = None
    backend = state.default_backend
    provider = backend_provider_name(backend)
    status_code = 200
    reason = None
    try:
        try:
            model_served, model_switch = await resolve_model(
                session=session,
                requested=requested_model if isinstance(requested_model, str) else None,
                allow_switch=allow_switch,
            )
        except BackendAuthError as exc:
            status_code = 503
            reason = "backend_auth_error"
            return backend_auth_response(backend, provider, str(exc))
        backend = state.resolve_backend(model_served)
        provider = backend_provider_name(backend)

        use_dry_run = state.enable_test_mode and header_bool(request.headers.get("X-Gate-Dry-Run"))
        if use_dry_run:
            sleep_seconds = extract_test_sleep_seconds(request)
            if sleep_seconds > 0:
                await asyncio.sleep(sleep_seconds)
            content = f"gate dry-run response for session={session} model={model_served} backend={backend}"
        else:
            try:
                upstream_status, upstream_json, upstream_text = await backend_chat_completion(
                    backend,
                    model_served,
                    payload.get("messages", []),
                )
            except BackendAuthError as exc:
                status_code = 503
                reason = "backend_auth_error"
                return backend_auth_response(backend, provider, str(exc))
            except ConnectionError as exc:
                status_code = 503
                reason = "backend_unavailable"
                return backend_unavailable_response(backend, model_served, str(exc))
            except Exception as exc:
                status_code = 500
                reason = "backend_config_error"
                return JSONResponse(
                    status_code=500,
                    content={
                        "error": {
                            "message": str(exc),
                            "type": "backend_config_error",
                            "backend": backend,
                            "provider": provider,
                        }
                    },
                )

            if upstream_status >= 500 and backend == "trtllm":
                status_code = 503
                reason = "backend_unavailable"
                return backend_unavailable_response(
                    backend,
                    model_served,
                    f"HTTP {upstream_status}: {upstream_text[:300]}",
                )

            if upstream_status >= 400:
                status_code = upstream_status
                reason = "upstream_error"
                return JSONResponse(
                    status_code=upstream_status,
                    content={
                        "error": {
                            "message": upstream_text,
                            "type": "upstream_error",
                            "backend": backend,
                            "provider": provider,
                        }
                    },
                )

            backend_cfg = state.backend_config(backend) or {}
            protocol = str(backend_cfg.get("protocol", ""))
            content = chat_content_from_upstream(protocol, upstream_json)

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
                "X-Gate-Backend": backend,
                "X-Gate-Provider": provider,
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
                backend=backend,
                provider=provider,
                model_switch=model_switch,
                reason=reason,
            )
        )


@app.post("/v1/embeddings")
async def v1_embeddings(request: Request) -> JSONResponse:
    payload = await request.json()
    requested_model = payload.get("model") if isinstance(payload.get("model"), str) else None
    input_value = payload.get("input")

    if isinstance(input_value, str):
        inputs = [input_value]
    elif isinstance(input_value, list) and all(isinstance(item, str) for item in input_value):
        inputs = input_value
    else:
        return JSONResponse(
            status_code=400,
            content={
                "error": {
                    "message": "input must be a string or an array of strings",
                    "type": "invalid_request_error",
                }
            },
        )

    if not inputs:
        return JSONResponse(
            status_code=400,
            content={"error": {"message": "input must not be empty", "type": "invalid_request_error"}},
        )

    session = request.headers.get("X-Agent-Session", "embeddings")
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
                endpoint="/v1/embeddings",
                decision="denied",
                model_requested=requested_model,
                model_served=None,
                status_code=429,
                latency_ms=latency_ms,
                backend=state.default_backend,
                provider=backend_provider_name(state.default_backend),
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
    model_served: str | None = None
    backend = state.default_backend
    provider = backend_provider_name(backend)
    status_code = 200
    reason = None
    try:
        try:
            model_served, model_switch = await resolve_model(
                session=session,
                requested=requested_model,
                allow_switch=allow_switch,
            )
        except BackendAuthError as exc:
            status_code = 503
            reason = "backend_auth_error"
            return backend_auth_response(backend, provider, str(exc))
        backend = state.resolve_backend(model_served)
        provider = backend_provider_name(backend)

        use_dry_run = state.enable_test_mode and header_bool(request.headers.get("X-Gate-Dry-Run"))
        vectors: list[list[float]] = []
        if use_dry_run:
            for item in inputs:
                vectors.append(deterministic_embedding_vector(f"{model_served}:{item}:{backend}"))
        else:
            for item in inputs:
                try:
                    upstream_status, upstream_json, upstream_text = await backend_embedding(
                        backend,
                        model_served,
                        item,
                    )
                except BackendAuthError as exc:
                    status_code = 503
                    reason = "backend_auth_error"
                    return backend_auth_response(backend, provider, str(exc))
                except ConnectionError as exc:
                    status_code = 503
                    reason = "backend_unavailable"
                    return backend_unavailable_response(backend, model_served, str(exc))
                except Exception as exc:
                    status_code = 500
                    reason = "backend_config_error"
                    return JSONResponse(
                        status_code=500,
                        content={
                            "error": {
                                "message": str(exc),
                                "type": "backend_config_error",
                                "backend": backend,
                                "provider": provider,
                            }
                        },
                    )

                if upstream_status >= 500 and backend == "trtllm":
                    status_code = 503
                    reason = "backend_unavailable"
                    return backend_unavailable_response(
                        backend,
                        model_served,
                        f"HTTP {upstream_status}: {upstream_text[:300]}",
                    )

                if upstream_status >= 400:
                    status_code = upstream_status
                    reason = "upstream_error"
                    return JSONResponse(
                        status_code=upstream_status,
                        content={
                            "error": {
                                "message": upstream_text,
                                "type": "upstream_error",
                                "backend": backend,
                                "provider": provider,
                            }
                        },
                    )

                backend_cfg = state.backend_config(backend) or {}
                protocol = str(backend_cfg.get("protocol", ""))
                embedding = embedding_from_upstream(protocol, upstream_json)
                if embedding is None:
                    status_code = 502
                    reason = "upstream_invalid_payload"
                    return JSONResponse(
                        status_code=502,
                        content={
                            "error": {
                                "message": "upstream embeddings payload is missing vector",
                                "type": "upstream_invalid_payload",
                                "backend": backend,
                                "provider": provider,
                            }
                        },
                    )
                vectors.append(embedding)

        response_payload = {
            "object": "list",
            "data": [
                {"object": "embedding", "index": idx, "embedding": vector}
                for idx, vector in enumerate(vectors)
            ],
            "model": model_served,
            "usage": {"prompt_tokens": 0, "total_tokens": 0},
        }
        return JSONResponse(
            status_code=200,
            content=response_payload,
            headers={
                "X-Gate-Decision": decision,
                "X-Model-Served": model_served or "",
                "X-Gate-Backend": backend,
                "X-Gate-Provider": provider,
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
                endpoint="/v1/embeddings",
                decision="denied" if status_code == 429 else decision,
                model_requested=requested_model,
                model_served=model_served,
                status_code=status_code,
                latency_ms=latency_ms,
                backend=backend,
                provider=provider,
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
    backend = state.resolve_backend(model)
    provider = backend_provider_name(backend)
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
            backend=backend,
            provider=provider,
            model_switch=True,
        )
    )
    return JSONResponse(
        status_code=200,
        content={
            "ok": True,
            "session": session_id,
            "model": model,
            "backend": backend,
            "provider": provider,
        },
    )


@app.get("/admin/sessions/{session_id}")
async def admin_session(session_id: str) -> JSONResponse:
    model = await state.get_sticky_model(session_id)
    backend = state.resolve_backend(model)
    provider = backend_provider_name(backend)
    return JSONResponse(
        status_code=200,
        content={"session": session_id, "model": model, "backend": backend, "provider": provider},
    )
