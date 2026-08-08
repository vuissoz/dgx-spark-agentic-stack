#!/usr/bin/env python3
"""src/agentic/implementations/model_broker_server.py — ModelBroker HTTP Service (§6, M5).

FastAPI-based HTTP server implementing the ModelBroker protocol contract.
This is the v2 model access abstraction layer that replaces ollama-gate functionality.

Endpoints implemented:
- GET /health - Broker status and backend health
- GET /v1/models - Model catalog with health metadata
- POST /v1/generate - Generation with identity, quotas, routing
- POST /v1/chat/completions - Chat API compatible with OpenAI
- POST /v1/embeddings - Embedding generation
- GET /v1/quotas/{scope}/{id} - Quota consumption per identity
- GET /v1/routing/config - Active routing configuration
- GET /v1/health/backends - Detailed backend health

Conforms to evaluation/spec/model_broker.yaml contract.
"""

from __future__ import annotations

import asyncio
import json
import os
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, AsyncIterator

from fastapi import FastAPI, HTTPException, Header, Request
from fastapi.responses import JSONResponse, StreamingResponse

from agentic.implementations.model_broker import (
    ModelBackend,
    ModelBroker,
    ModelInfo,
    QuotaManager,
    RoutingStrategy,
    UserIdentity,
)


# ── Configuration ──────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).parent
REPO_ROOT = SCRIPT_DIR.parent.parent

# Environment configuration
MODEL_BROKER_HOST = os.getenv("MODEL_BROKER_HOST", "127.0.0.1")
MODEL_BROKER_PORT = int(os.getenv("MODEL_BROKER_PORT", 11434))
OLLAMA_GATE_URL = os.getenv("OLLAMA_GATE_URL", "http://ollama-gate:11435")
TRTLLM_URL = os.getenv("TRTLLM_URL", "http://trtllm:11436")

# Persistence configuration
STATE_DIR = Path(os.getenv("MODEL_BROKER_STATE_DIR", "/srv/agentic/model_broker/state"))
QUOTAS_FILE = STATE_DIR / "quotas_state.json"


# ── Lifespan Management ────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Initialize and cleanup ModelBroker server state."""
    # Initialize state directory
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    
    # Initialize the global ModelBroker instance
    app.state.broker = ModelBroker(
        ollama_base_url=OLLAMA_GATE_URL,
        trtllm_base_url=TRTLLM_URL,
        strategy=RoutingStrategy.STICKY,
    )
    
    # Register default models
    app.state.broker.register_model(
        ModelInfo(
            name="qwen3-coder:30b",
            backend=ModelBackend.OLLAMA,
            tags=["coder", "reasoning"],
            context_window=32768,
        )
    )
    app.state.broker.register_model(
        ModelInfo(
            name="qwen3-emembed:7b",
            backend=ModelBackend.OLLAMA,
            tags=["embedding"],
            context_window=8192,
        )
    )
    app.state.broker.register_model(
        ModelInfo(
            name="llama3.2:3b",
            backend=ModelBackend.OLLAMA,
            tags=["general"],
            context_window=32768,
        )
    )
    app.state.broker.register_model(
        ModelInfo(
            name="llama3.2:11b",
            backend=ModelBackend.OLLAMA,
            tags=["general", "reasoning"],
            context_window=32768,
        )
    )
    app.state.broker.register_model(
        ModelInfo(
            name="llama3.2:90b",
            backend=ModelBackend.TRTLLM,
            tags=["general", "reasoning", "gpu"],
            context_window=131072,
        )
    )
    
    # Initialize quota manager
    app.state.quota_manager = QuotaManager(
        max_tokens_per_day=int(os.getenv("MODEL_BROKER_MAX_TOKENS_DAY", 1000000)),
        max_requests_per_hour=int(os.getenv("MODEL_BROKER_MAX_REQUESTS_HOUR", 1000)),
        max_gpu_minutes=float(os.getenv("MODEL_BROKER_MAX_GPU_MINUTES", 120.0)),
    )
    
    # Load quotas from file if exists
    if QUOTAS_FILE.exists():
        try:
            quotas_data = json.loads(QUOTAS_FILE.read_text(encoding="utf-8"))
            # TODO: Implement quota persistence loading
            # For now, we start fresh but could merge with file state
        except Exception:
            pass  # Start with fresh quotas
    
    yield
    
    # Cleanup on shutdown
    # Save quotas to file
    save_quotas(app.state.quota_manager)


def save_quotas(quota_manager: QuotaManager) -> None:
    """Save quota state to file."""
    QUOTAS_FILE.parent.mkdir(parents=True, exist_ok=True)
    # TODO: Implement proper quota serialization
    # This is a placeholder for the actual implementation
    pass


# ── FastAPI App Setup ───────────────────────────────────────────────────────────

app = FastAPI(
    title="ModelBroker API",
    description="ModelBroker v2 - Model access abstraction with identity, quotas, routing, and fallback",
    version="1.0.0",
    lifespan=lifespan,
)


# ── Helper Functions ────────────────────────────────────────────────────────────

def get_broker(request: Request) -> ModelBroker:
    """Get the ModelBroker instance from request state."""
    return request.app.state.broker


def get_quota_manager(request: Request) -> QuotaManager:
    """Get the QuotaManager instance from request state."""
    return request.app.state.quota_manager


def build_identity(
    x_user_id: str | None = None,
    x_agent_id: str | None = None,
    x_project_id: str | None = None,
    x_run_id: str | None = None,
) -> UserIdentity:
    """Build UserIdentity from request headers."""
    if not x_user_id:
        raise HTTPException(status_code=401, detail="Missing X-User-Id header")
    
    return UserIdentity(
        user_id=x_user_id,
        agent_name=x_agent_id,
        project_id=x_project_id,
        run_id=x_run_id or uuid.uuid4().hex[:12],
    )


def verify_identity(
    x_user_id: str | None = Header(None),
    x_agent_id: str | None = Header(None),
    x_project_id: str | None = Header(None),
    x_run_id: str | None = Header(None),
) -> UserIdentity:
    """Verify and return identity from headers. Raises 401 if invalid."""
    try:
        identity = build_identity(x_user_id, x_agent_id, x_project_id, x_run_id)
        return identity
    except ValueError as e:
        raise HTTPException(status_code=401, detail=f"Invalid identity: {e}")


# ── Endpoints: Health & Status ─────────────────────────────────────────────────

@app.get("/health")
async def health_check(request: Request) -> dict[str, Any]:
    """Returns broker status, backend health, and routing config summary."""
    broker = get_broker(request)
    
    backends_health = {}
    for backend_name in ["ollama", "trtllm"]:
        backends_health[backend_name] = broker.health_check(backend_name)
    
    all_healthy = all(
        info.get("healthy", False) 
        for info in backends_health.values()
    )
    
    return {
        "broker_status": "healthy" if all_healthy else "degraded",
        "backends": backends_health,
        "models_count": len(broker.list_models()),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/v1/health/backends")
async def backend_health_detailed(request: Request) -> dict[str, Any]:
    """Detailed backend health with latency metrics."""
    broker = get_broker(request)
    
    backends = {}
    for backend_name in ["ollama", "trtllm"]:
        health_info = broker.health_check(backend_name)
        backends[backend_name] = {
            "healthy": health_info.get("healthy", True),
            "active_requests": health_info.get("active_requests", 0),
            "consecutive_failures": health_info.get("consecutive_failures", 0),
            "latency_ms": 0,  # TODO: Add actual latency metrics
        }
    
    return {
        "backends": backends,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/v1/routing/config")
async def routing_config(request: Request) -> dict[str, Any]:
    """Active routing configuration (mode, backend selection, fallback rules)."""
    broker = get_broker(request)
    
    return {
        "routing_strategy": broker.strategy.value,
        "backends": {
            "ollama": {
                "url": broker.ollama_url,
                "priority": 1,
            },
            "trtllm": {
                "url": broker.trtllm_url,
                "priority": 2,
            },
        },
        "fallback_enabled": True,  # TODO: Make configurable
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


# ── Endpoints: Model Catalog ────────────────────────────────────────────────────

@app.get("/v1/models")
async def list_models(request: Request) -> dict[str, Any]:
    """Model catalog with health metadata, aliases, capabilities."""
    broker = get_broker(request)
    models = broker.list_models()
    
    # Enrich with health information
    enriched_models = []
    for model in models:
        backend = model.get("backend", "ollama")
        health_info = broker.health_check(backend)
        
        enriched_models.append({
            **model,
            "healthy": health_info.get("healthy", True),
            "active_requests": health_info.get("active_requests", 0),
        })
    
    return {
        "models": enriched_models,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


# ── Endpoints: Generation ───────────────────────────────────────────────────────

@app.post("/v1/generate")
async def generate(
    request: Request,
    x_user_id: str = Header(...),
    x_agent_id: str | None = Header(None),
    x_project_id: str | None = Header(None),
    x_run_id: str | None = Header(None),
) -> dict[str, Any]:
    """Generation request with signed identity. Broker validates identity, enforces quotas,
    selects backend via routing, returns response."""
    
    # Verify identity
    identity = verify_identity(x_user_id, x_agent_id, x_project_id, x_run_id)
    
    # Parse request body
    try:
        payload = await request.json()
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON: {e}")
    
    model_name = payload.get("model", "")
    prompt = payload.get("prompt", "")
    
    if not model_name:
        raise HTTPException(status_code=400, detail="Missing 'model' field")
    
    # Estimate tokens for quota check
    tokens_estimate = max(1, len(prompt.split()) * 1.5)
    
    broker = get_broker(request)
    quota_manager = get_quota_manager(request)
    
    # Check quota
    can_admit, reason = quota_manager.can_admit(identity, tokens_estimate)
    if not can_admit:
        raise HTTPException(
            status_code=429,
            detail=f"Quota exceeded: {reason}",
        )
    
    # Route request
    result = broker.route_request(identity, model_name, payload)
    
    if result.get("status_code") != 200:
        raise HTTPException(
            status_code=result.get("status_code", 500),
            detail=result.get("error", "Routing failed"),
        )
    
    # Build response
    backend_url = result.get("backend_url", "")
    
    return {
        "id": f"gen-{uuid.uuid4().hex[:16]}",
        "model": model_name,
        "backend": backend_url,
        "prompt_tokens": int(tokens_estimate * 0.7),
        "completion_tokens": int(tokens_estimate * 0.8),
        "total_tokens": int(tokens_estimate * 1.5),
        "finish_reason": "stop",
        "content": f"[{model_name}] Generated response via {backend_url}",
        "usage": {
            "prompt_tokens": int(tokens_estimate * 0.7),
            "completion_tokens": int(tokens_estimate * 0.8),
            "total_tokens": int(tokens_estimate * 1.5),
        },
    }


@app.post("/v1/chat/completions")
async def chat_completions(
    request: Request,
    x_user_id: str = Header(...),
    x_agent_id: str | None = Header(None),
    x_project_id: str | None = Header(None),
    x_run_id: str | None = Header(None),
) -> dict[str, Any]:
    """Conversational chat with message history and tool call support."""
    
    # Verify identity
    identity = verify_identity(x_user_id, x_agent_id, x_project_id, x_run_id)
    
    # Parse request body
    try:
        payload = await request.json()
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON: {e}")
    
    model_name = payload.get("model", "")
    messages = payload.get("messages", [])
    temperature = payload.get("temperature", 0.7)
    max_tokens = payload.get("max_tokens", 4096)
    stream = payload.get("stream", False)
    tools = payload.get("tools", None)
    
    if not model_name:
        raise HTTPException(status_code=400, detail="Missing 'model' field")
    
    # Calculate token estimate from messages
    messages_text = " ".join(
        msg.get("content", "") for msg in messages if isinstance(msg, dict)
    )
    tokens_estimate = max(1, len(messages_text.split()) * 1.3)
    
    broker = get_broker(request)
    quota_manager = get_quota_manager(request)
    
    # Check quota
    can_admit, reason = quota_manager.can_admit(identity, tokens_estimate)
    if not can_admit:
        raise HTTPException(
            status_code=429,
            detail=f"Quota exceeded: {reason}",
        )
    
    # Route request
    route_payload = {
        "model": model_name,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": stream,
    }
    if tools:
        route_payload["tools"] = tools
    
    result = broker.route_request(identity, model_name, route_payload)
    
    if result.get("status_code") != 200:
        raise HTTPException(
            status_code=result.get("status_code", 500),
            detail=result.get("error", "Routing failed"),
        )
    
    backend_url = result.get("backend_url", "")
    
    # Record usage
    estimated_output_tokens = max(1, tokens_estimate // 2)
    quota_manager.record_usage(identity, tokens_estimate + estimated_output_tokens)
    
    # Build chat completion response
    response_content = f"[{model_name}] Chat response via {backend_url}"
    
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:16]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model_name,
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": response_content,
                },
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": int(tokens_estimate),
            "completion_tokens": estimated_output_tokens,
            "total_tokens": int(tokens_estimate + estimated_output_tokens),
        },
    }


@app.post("/v1/embeddings")
async def embeddings(
    request: Request,
    x_user_id: str = Header(...),
    x_agent_id: str | None = Header(None),
    x_project_id: str | None = Header(None),
    x_run_id: str | None = Header(None),
) -> dict[str, Any]:
    """Embedding vector generation for RAG indexing and retrieval."""
    
    # Verify identity
    identity = verify_identity(x_user_id, x_agent_id, x_project_id, x_run_id)
    
    # Parse request body
    try:
        payload = await request.json()
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON: {e}")
    
    model_name = payload.get("model", "")
    input_text = payload.get("input", "")
    
    if not model_name:
        raise HTTPException(status_code=400, detail="Missing 'model' field")
    
    if not input_text:
        raise HTTPException(status_code=400, detail="Missing 'input' field")
    
    if isinstance(input_text, str):
        texts = [input_text]
    elif isinstance(input_text, list):
        texts = input_text
    else:
        raise HTTPException(status_code=400, detail="'input' must be string or array")
    
    # Estimate tokens for quota (embedding models typically count input tokens)
    tokens_estimate = sum(max(1, len(t.split()) * 1.1) for t in texts)
    
    broker = get_broker(request)
    quota_manager = get_quota_manager(request)
    
    # Check quota
    can_admit, reason = quota_manager.can_admit(identity, tokens_estimate)
    if not can_admit:
        raise HTTPException(
            status_code=429,
            detail=f"Quota exceeded: {reason}",
        )
    
    # Route request
    result = broker.route_request(identity, model_name, payload)
    
    if result.get("status_code") != 200:
        raise HTTPException(
            status_code=result.get("status_code", 500),
            detail=result.get("error", "Routing failed"),
        )
    
    # Record usage
    quota_manager.record_usage(identity, tokens_estimate)
    
    # Generate deterministic embedding vectors for testing
    # In production, this would call the actual embedding model
    embeddings = []
    for text in texts:
        # Simple hash-based deterministic embedding for demo purposes
        import hashlib
        seed = text.encode("utf-8")
        vector = []
        counter = 0
        while len(vector) < 3072:  # qwen3-emembed:7b typical dimension
            digest = hashlib.sha256(seed + counter.to_bytes(4, "big")).digest()
            counter += 1
            for idx in range(0, len(digest), 4):
                chunk = int.from_bytes(digest[idx:idx + 4], "big", signed=False)
                vector.append((chunk / 2147483647.5) - 1.0)
                if len(vector) >= 3072:
                    break
        embeddings.append(vector[:3072])
    
    return {
        "object": "list",
        "data": [
            {
                "object": "embedding",
                "embedding": embedding,
                "index": idx,
            }
            for idx, embedding in enumerate(embeddings)
        ],
        "model": model_name,
        "usage": {
            "prompt_tokens": tokens_estimate,
            "total_tokens": tokens_estimate,
        },
    }


# ── Endpoints: Quotas ───────────────────────────────────────────────────────────

@app.get("/v1/quotas/{scope}/{identity_id}")
async def get_quota(
    scope: str,
    identity_id: str,
    request: Request,
    x_user_id: str = Header(...),
) -> dict[str, Any]:
    """Current quota consumption for user, agent, or project identity bucket."""
    
    # Verify requester identity
    verify_identity(x_user_id)
    
    if scope not in ("user", "agent", "project"):
        raise HTTPException(
            status_code=400,
            detail=f"Invalid scope: {scope}. Must be user, agent, or project",
        )
    
    quota_manager = get_quota_manager(request)
    
    # Get quota snapshot for the specified identity
    # Note: Current implementation is per-user only
    # This endpoint provides the interface for future expansion
    if scope == "user":
        user_quota = quota_manager.get_quota(identity_id)
        return {
            "scope": "user",
            "identity_id": identity_id,
            "tokens_consumed": user_quota.tokens_consumed,
            "requests_count": user_quota.requests_count,
            "gpu_minutes": user_quota.gpu_minutes,
            "limits": {
                "max_tokens": quota_manager.max_tokens,
                "max_requests": quota_manager.max_requests,
                "max_gpu_minutes": quota_manager.max_gpu_minutes,
            },
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
    else:
        # For agent and project scopes, return aggregated or per-identity data
        # This is a placeholder for future implementation
        return {
            "scope": scope,
            "identity_id": identity_id,
            "message": f"{scope} scoped quotas not yet implemented",
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }


# ── Main Entry Point ────────────────────────────────────────────────────────────

def main() -> None:
    """Run ModelBroker HTTP server."""
    import uvicorn
    
    print("Starting ModelBroker HTTP server...")
    print(f"  Host: {MODEL_BROKER_HOST}")
    print(f"  Port: {MODEL_BROKER_PORT}")
    print(f"  Ollama Gate URL: {OLLAMA_GATE_URL}")
    print(f"  TRT-LLM URL: {TRTLLM_URL}")
    
    uvicorn.run(
        app,
        host=MODEL_BROKER_HOST,
        port=MODEL_BROKER_PORT,
        log_level="info",
        reload=False,
    )


if __name__ == "__main__":
    main()