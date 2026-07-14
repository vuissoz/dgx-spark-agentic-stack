#!/usr/bin/env python3
"""src/agentic/implementations/model_broker.py — ModelBroker implementation (§6, §17).

This is the concrete ModelBrokerAdapter that handles:
- Model routing (Ollama / TensorRT-LLM / remote providers)
- Quota management and usage tracking
- Identity signaturer (user/agent/project/run)
- Fallback routing on backend failure
- GPU admission coordination with scheduler

Replaces ollama-gate as the v2 model access abstraction layer.
"""

from __future__ import annotations

import asyncio
import json
import os
import time
import uuid
from dataclasses import dataclass, field, replace
from enum import Enum
from typing import Any, Optional


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.join(SCRIPT_DIR, "..", "..")


# ── Enums & Data Models ──────────────────────────────────────────────────

class ModelBackend(Enum):
    """Supported model backends for routing."""
    OLLAMA = "ollama"
    TRTLLM = "trtllm"
    VLLM = "vllm"
    OPENAI = "openai"      # via ollama-gate OpenAI-compatible endpoint
    OPENROUTER = "openrouter"  # via ollama-gate proxy


class RoutingStrategy(Enum):
    """How to select a backend for a model request."""
    STICKY = "sticky"           # Same session → same backend (default)
    ROUND_ROBIN = "round_robin" # Distribute across healthy backends
    LOAD_BALANCED = "load_balanced" # Lowest active requests


class UserIdentity:
    """Signed identity for model request context. (§6.3)"""
    def __init__(self, user_id: str, agent_name: Optional[str] = None,
                 project_id: Optional[str] = None, run_id: Optional[str] = None):
        self.user_id = user_id
        self.agent_name = agent_name
        self.project_id = project_id
        self.run_id = run_id or uuid.uuid4().hex[:12]

    def to_header(self) -> dict[str, str]:
        """Serialize identity for injection into model requests."""
        headers: dict[str, str] = {
            "x-user-id": self.user_id,
            "x-run-id": self.run_id,
        }
        if self.agent_name:
            headers["x-agent-name"] = self.agent_name
        if self.project_id:
            headers["x-project-id"] = self.project_id
        return headers


@dataclass(frozen=True)
class ModelInfo:
    """Metadata for a registered model."""
    name: str
    backend: ModelBackend
    tags: list[str] = field(default_factory=list)
    alias_of: Optional[str] = None  # alias → canonical model
    context_window: int = 32768


@dataclass(frozen=True)
class QuotaSnapshot:
    """Usage snapshot for quota enforcement."""
    user_id: str
    project_id: str
    tokens_consumed: int = 0
    requests_count: int = 0
    gpu_minutes: float = 0.0


# ── Backend Health Tracker ───────────────────────────────────────────────

class BackendHealthTracker:
    """Tracks health status of model backends for routing decisions."""

    def __init__(self):
        self._backends: dict[str, dict] = {}

    def record_health(self, backend_name: str, healthy: bool) -> None:
        self._backends[backend_name] = {
            "healthy": healthy,
            "last_check": time.time(),
            "active_requests": 0,
            "consecutive_failures": 0,
        }

    def mark_request_start(self, backend_name: str) -> None:
        if backend_name in self._backends:
            self._backends[backend_name]["active_requests"] += 1

    def mark_request_end(self, backend_name: str, success: bool) -> None:
        if backend_name not in self._backends:
            return
        b = self._backends[backend_name]
        b["active_requests"] = max(0, b["active_requests"] - 1)
        if success:
            b["consecutive_failures"] = 0
            if not b["healthy"]:
                b["healthy"] = True  # Recovery
        else:
            b["consecutive_failures"] += 1
            if b["consecutive_failures"] >= 3:
                b["healthy"] = False

    def get_healthy_backends(self, strategy: RoutingStrategy) -> list[str]:
        """Return healthy backends sorted by strategy."""
        healthy = [name for name, info in self._backends.items() if info.get("healthy", True)]
        
        if strategy == RoutingStrategy.STICKY:
            return healthy  # Sticky is resolved per-session
        
        # Sort by active requests (load_balanced) or round-robin via stable sort
        healthy.sort(key=lambda n: self._backends[n]["active_requests"])
        return healthy


# ── Quota Manager ────────────────────────────────────────────────────────

class QuotaManager:
    """Manages per-user/project quotas for token/requests/GPU usage."""

    def __init__(self, max_tokens_per_day: int = 1_000_000,
                 max_requests_per_hour: int = 500, max_gpu_minutes: float = 60.0):
        self.max_tokens = max_tokens_per_day
        self.max_requests = max_requests_per_hour
        self.max_gpu_minutes = max_gpu_minutes
        self._quotas: dict[str, QuotaSnapshot] = {}

    def get_quota(self, user_id: str) -> QuotaSnapshot:
        """Get or create a quota record for user."""
        if user_id not in self._quotas:
            self._quotas[user_id] = QuotaSnapshot(
                user_id=user_id, project_id="personal",
            )
        return self._quotas[user_id]

    def can_admit(self, identity: UserIdentity, tokens_estimate: int) -> tuple[bool, str]:
        """Check if request can be admitted under quota limits."""
        q = self.get_quota(identity.user_id)
        
        # Token budget check
        if q.tokens_consumed + tokens_estimate > self.max_tokens:
            return False, f"Token budget exhausted ({q.tokens_consumed}/{self.max_tokens})"
        
        # Request count check  
        if q.requests_count >= self.max_requests:
            return False, f"Request limit reached ({q.requests_count}/{self.max_requests})"
        
        # GPU time check (for GPU-dependent backends)
        if identity.project_id and identity.project_id in ["gpu-intensive"]:
            estimated_gpu_min = tokens_estimate / 1000.0  # rough estimate: 1k tokens ≈ 1min GPU
            if q.gpu_minutes + estimated_gpu_min > self.max_gpu_minutes:
                return False, f"GPU budget exceeded ({q.gpu_minutes:.1f}/{self.max_gpu_minutes}min)"
        
        return True, ""

    def record_usage(self, identity: UserIdentity, tokens_consumed: int) -> None:
        """Record token usage after completion."""
        q = self.get_quota(identity.user_id)  # Ensures entry exists
        
        # Estimate GPU minutes for GPU-intensive projects (1k tokens ≈ 1 min)
        estimated_gpu_min = 0.0
        if identity.project_id and identity.project_id in ["gpu-intensive"]:
            estimated_gpu_min = tokens_consumed / 1000.0
        
        new_q = replace(
            q,
            tokens_consumed=q.tokens_consumed + tokens_consumed,
            requests_count=q.requests_count + 1,
            gpu_minutes=q.gpu_minutes + estimated_gpu_min,
        )
        self._quotas[identity.user_id] = new_q


# ── ModelBroker Core ─────────────────────────────────────────────────────

class ModelBroker:
    """Concrete ModelBrokerAdapter (§6).

    Routes model requests to appropriate backends (Ollama/TRT-LLM/remote)
    with identity signing, quota enforcement, and fallback routing.
    """

    def __init__(self, ollama_base_url: str = "http://ollama-gate:11435",
                 trtllm_base_url: str = "http://trtllm:11436",
                 strategy: RoutingStrategy = RoutingStrategy.STICKY):
        self.ollama_url = ollama_base_url
        self.trtllm_url = trtllm_base_url
        self.strategy = strategy
        
        # State
        self._models: dict[str, ModelInfo] = {}
        self._sticky_map: dict[str, str] = {}  # session → backend name
        self._health = BackendHealthTracker()
        self._quota = QuotaManager()

    # ── Public API ───────────────────────────────────────────────────────
    
    def register_model(self, model_info: ModelInfo) -> None:
        """Register a model with its backend and metadata."""
        self._models[model_info.name] = model_info
        # Auto-register backend health
        if model_info.backend == ModelBackend.OLLAMA:
            self._health.record_health("ollama", True)
        elif model_info.backend == ModelBackend.TRTLLM:
            self._health.record_health("trtllm", True)

    def list_models(self) -> list[dict[str, Any]]:
        """List all registered models (conforms to Ollama /api/tags)."""
        models = []
        for name, info in self._models.items():
            if info.alias_of and info.alias_of != name:
                # Alias entry pointing to canonical model
                models.append({
                    "name": name,
                    "parent": info.alias_of,
                    "tags": ["alias"] + info.tags,
                })
            else:
                models.append({
                    "name": name,
                    "backend": info.backend.value,
                    "tags": info.tags,
                    "context_window": info.context_window,
                })
        return models

    def route_request(self, identity: UserIdentity, model_name: str,
                      payload: dict[str, Any]) -> dict[str, Any]:
        """Route a model request through ModelBroker with quota and health checks."""
        # 1. Resolve target backend
        model = self._models.get(model_name)
        if not model:
            return {"error": f"Model not found: {model_name}", "status_code": 404}
        
        backend_name = self._select_backend(identity, model)
        
        # 2. Check quota
        tokens_est = len(payload.get("messages", [{}])[0].get("content", "").split()) * 3
        allowed, reason = self._quota.can_admit(identity, max(tokens_est, 100))
        if not allowed:
            return {"error": f"Quota exceeded: {reason}", "status_code": 429}
        
        # 3. Build routed payload with identity headers
        headers = identity.to_header()
        headers["x-model-name"] = model_name
        
        # 4. Execute request (stub — actual HTTP call goes to ollama-gate or trtllm)
        backend_url = self._get_backend_url(backend_name)
        
        return {
            "status_code": 200,
            "headers": headers,
            "backend_url": backend_url,
            "model": model_name,
            "payload_size_estimate": tokens_est,
            "identity": identity.__dict__,
        }

    def health_check(self, backend_name: str) -> dict[str, Any]:
        """Check health of a specific backend."""
        info = self._health._backends.get(backend_name, {})
        return {
            "backend": backend_name,
            "healthy": info.get("healthy", True),
            "active_requests": info.get("active_requests", 0),
            "consecutive_failures": info.get("consecutive_failures", 0),
        }

    def record_usage(self, identity: UserIdentity, model_name: str, tokens_consumed: int) -> None:
        """Record token usage after request completion."""
        self._quota.record_usage(identity, tokens_consumed)

    # ── Internal helpers ────────────────────────────────────────────────
    
    def _select_backend(self, identity: UserIdentity, model: ModelInfo) -> str:
        """Select target backend for a model request."""
        session_key = f"{identity.user_id}:{identity.project_id or 'personal'}"
        
        if self.strategy == RoutingStrategy.STICKY:
            # Use cached sticky backend if healthy, else fall back
            if session_key in self._sticky_map:
                cached = self._sticky_map[session_key]
                health = self._health.get_healthy_backends(self.strategy)
                if cached in health or model.backend.value == cached:
                    return cached
        
        # Select fresh backend from healthy pool matching model's preferred backend
        for backend_name in self._health.get_healthy_backends(self.strategy):
            if backend_name == model.backend.value:
                break
        else:
            # Fallback to any healthy backend
            backends = self._health.get_healthy_backends(self.strategy)
            backend_name = backends[0] if backends else "ollama"
        
        # Cache for sticky routing
        if self.strategy == RoutingStrategy.STICKY and session_key:
            self._sticky_map[session_key] = backend_name
        
        return backend_name

    def _get_backend_url(self, backend_name: str) -> str:
        """Map backend name to its URL."""
        urls = {
            "ollama": self.ollama_url,
            "trtllm": self.trtllm_url,
            "vllm": os.environ.get("VLLM_BASE_URL", "http://vllm:8000"),
        }
        return urls.get(backend_name, self.ollama_url)


# ── CLI entry point ──────────────────────────────────────────────────────

def main() -> int:
    """Quick diagnostic for ModelBroker state."""
    import argparse
    
    parser = argparse.ArgumentParser(description="ModelBroker — diagnostic")
    parser.add_argument("--action", choices=["list-models", "health", "status"], default="status")
    args = parser.parse_args()

    broker = ModelBroker()
    
    # Register example models
    broker.register_model(ModelInfo(name="qwen3-coder:30b", backend=ModelBackend.OLLAMA, tags=["coder"]))
    broker.register_model(ModelInfo(name="qwen3-emembed:7b", backend=ModelBackend.OLLAMA, tags=["embedding"]))

    if args.action == "list-models":
        models = broker.list_models()
        print(json.dumps(models, indent=2))
    elif args.action == "health":
        for name in ["ollama", "trtllm"]:
            print(f"{name}: {broker.health_check(name)}")
    elif args.action == "status":
        print("ModelBroker status:")
        print(f"  Models registered: {len(broker.list_models())}")
        print(f"  Strategy: {broker.strategy.value}")

    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
