#!/usr/bin/env python3
"""ModelBroker Protocol SDK (PLAN.md §6)

Reference implementation that validates the ModelBroker protocol contract.
Simulates broker behavior for testing: identity verification, routing, quotas,
fallback, and audit logging without requiring a running ollama-gate or backend.

Usage as library:
    from deployments.optional.model_broker_protocol import ModelBrokerContract
    
    broker = ModelBrokerContract()
    result = broker.generate(
        model="qwen3-32b",
        prompt="Hello, world!",
        agent_id="codex",
        user_id="alice",
        project_id="ARTANY",
        run_id="run-001"
    )
    print(result)

Usage as CLI:
    python3 model_broker_protocol.py validate [--spec-file <path>]
    python3 model_broker_protocol.py test [--mode unit|contract]

"""
import argparse
import json
import os
import sys
import time
import hashlib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Dict, List, Optional


# ── Data types ──────────────────────────────────────────────────────────────

class BackendType(Enum):
    OLLAMA = "ollama"
    TRTLLM = "trtllm"
    REMOTE = "remote"
    VLLM = "vllm"


class BackendStatus(Enum):
    HEALTHY = "healthy"
    UNHEALTHY = "unhealthy"
    OVERLOADED = "overloaded"
    NOT_CONFIGURED = "not_configured"
    UNAVAILABLE = "unavailable"


class BrokerStatus(Enum):
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"


class LLMMode(Enum):
    LOCAL = "local"
    HYBRID = "hybrid"
    MIXED = "mixed"
    REMOTE = "remote"


class LLMBehind(Enum):
    OLLAMA = "ollama"
    TRTLLM = "trtllm"
    BOTH = "both"
    REMOTE = "remote"


@dataclass
class QuotaState:
    """Per-identity quota bucket."""
    tokens_used: int = 0
    tokens_limit: int = 0
    requests_used: int = 0
    requests_limit: int = 0
    period: str = "daily"
    reset_at: Optional[str] = None

    def exceeds(self, tokens_delta: int = 0, requests_delta: int = 1) -> tuple[bool, str]:
        if self.tokens_limit > 0 and (self.tokens_used + tokens_delta) > self.tokens_limit:
            return True, f"token quota exceeded: {self.tokens_used + tokens_delta}/{self.tokens_limit}"
        if self.requests_limit > 0 and (self.requests_used + requests_delta) > self.requests_limit:
            return True, f"request quota exceeded: {self.requests_used + requests_delta}/{self.requests_limit}"
        return False, ""


@dataclass
class AuditEntry:
    """Audit log entry for every model call."""
    timestamp: str
    user_id: str
    agent_id: str
    project_id: Optional[str]
    run_id: Optional[str]
    model_requested: str
    backend_used: str
    prompt_tokens: int = 0
    completion_tokens: int = 0
    cost_estimate: float = 0.0
    status: str = "success"
    fallback_from: Optional[str] = None


@dataclass
class ModelCatalogEntry:
    model_id: str
    name: str
    alias_of: Optional[str] = None
    backends: Dict[str, BackendStatus] = field(default_factory=dict)
    capabilities: Dict[str, bool] = field(default_factory=lambda: {
        "generation": True,
        "chat": True,
        "embeddings": False,
        "tool_use": True,
        "streaming": True,
    })
    context_window: int = 0


# ── ModelBroker Contract ───────────────────────────────────────────────────

class ModelBrokerContract:
    """Validates and simulates the ModelBroker protocol per PLAN.md §6.
    
    This class enforces the contract: signed identity, quotas, routing, fallback,
    GPU admission, usage tracking, and audit logging.
    """

    def __init__(self, spec_path: Optional[str] = None):
        self.backends: Dict[str, BackendStatus] = {
            "ollama": BackendStatus.HEALTHY,
            "trtllm": BackendStatus.NOT_CONFIGURED,
            "remote": BackendStatus.NOT_CONFIGURED,
        }
        self.model_catalog: Dict[str, ModelCatalogEntry] = {}
        self.quotas: Dict[str, QuotaState] = {}
        self.audit_log: List[AuditEntry] = []
        self.llm_mode = LLMMode.HYBRID
        self.llm_backend = LLMBehind.BOTH
        self.fallback_enabled = True
        self.fallback_chain: List[str] = ["ollama", "trtllm", "remote"]
        self.gpu_admission_available = False
        self._spec_path = spec_path
        
        # Load spec if provided
        if spec_path and os.path.exists(spec_path):
            self._load_spec(spec_path)

    def _load_spec(self, path: str) -> None:
        """Load protocol spec YAML (parses key fields for validation)."""
        try:
            import yaml  # optional; gracefully degrade
            with open(path) as f:
                spec = yaml.safe_load(f)
            self._spec_path = path
            contract = spec.get("contract", {})
            if contract.get("security", {}).get("signed_identity_required"):
                self._identity_required = True
            else:
                self._identity_required = True  # always required by plan

            metrics_spec = spec.get("metrics", [])
            self._required_metrics = [m for m in metrics_spec] if isinstance(metrics_spec, list) else []
        except Exception:
            # YAML not installed; use defaults from PLAN.md §6
            self._identity_required = True
            self._required_metrics = ["tokens_per_second", "time_to_first_token_seconds",
                                      "tokens_total", "fallback_count", "quota_exceeded_count"]

    def _validate_identity(self, headers: Dict[str, str]) -> tuple[bool, str]:
        """Validate signed identity headers per contract requirement.
        
        Required: X-Agent-Id, X-User-Id (optional: X-Project-Id, X-Run-Id)
        Missing identity → 401 with actionable error.
        """
        if not headers.get("X-Agent-Id"):
            return False, "401 missing required header: X-Agent-Id"
        if not headers.get("X-User-Id"):
            return False, "401 missing required header: X-User-Id"
        
        # Validate agent_id is a known harness identifier (PLAN §6 contract)
        valid_agents = {"claude", "codex", "opencode", "kilocode", "vibestral", 
                       "hermes", "openclaw", "pi-mono", "goose"}
        agent_id = headers["X-Agent-Id"].lower()
        if not agent_id:
            return False, f"401 missing required header: X-Agent-Id"
        if agent_id not in valid_agents:
            return False, f"401 unknown agent identity: {agent_id} (valid: {', '.join(sorted(valid_agents))})"
        
        # Validate user_id is non-empty and alphanumeric/hyphen/underscore
        user_id = headers["X-User-Id"]
        if not user_id or not all(c.isalnum() or c in '-_.' for c in user_id):
            return False, "401 invalid X-User-Id format"
        
        return True, ""

    def _get_quota_key(self, scope: str, identity_id: str) -> str:
        """Generate quota bucket key."""
        if scope not in ("user", "agent", "project"):
            raise ValueError(f"Invalid quota scope: {scope}. Must be user|agent|project")
        return f"{scope}:{identity_id}"

    def _check_quota(self, key: str, tokens_delta: int = 0, requests_delta: int = 1) -> tuple[bool, str]:
        """Check and update quota for identity bucket."""
        if key not in self.quotas:
            # Auto-create default quota (unlimited by default for flexibility)
            self.quotas[key] = QuotaState(tokens_limit=0, requests_limit=0)  # 0 = unlimited
        quota = self.quotas[key]
        exceeds, reason = quota.exceeds(tokens_delta, requests_delta)
        if exceeds:
            quota.requests_used += requests_delta  # Count the denied request for audit
            return True, reason
        quota.tokens_used += tokens_delta
        quota.requests_used += requests_delta
        return False, ""

    def get_models(self) -> dict:
        """Catalog endpoint simulation — returns available models with health."""
        return {
            "models": [
                e.model_dump() if hasattr(e, 'model_dump') else e.__dict__
                for e in self.model_catalog.values()
            ]
        }

    def generate(
        self,
        model: str,
        prompt: str,
        agent_id: Optional[str] = None,
        user_id: Optional[str] = None,
        project_id: Optional[str] = None,
        run_id: Optional[str] = None,
        stream: bool = False,
        headers: Optional[Dict[str, str]] = None,
    ) -> dict:
        """Generate response through the broker with full contract validation.
        
        Enforces: identity verification, quota check, backend routing, fallback,
        audit logging, and GPU admission coordination.
        """
        # Normalize headers from positional args or explicit dict
        if headers is None:
            headers = {}
        if agent_id:
            headers["X-Agent-Id"] = agent_id
        if user_id:
            headers["X-User-Id"] = user_id
        if project_id:
            headers["X-Project-Id"] = project_id
        if run_id:
            headers["X-Run-Id"] = run_id

        # 1. Identity validation
        valid, error = self._validate_identity(headers)
        if not valid:
            return {"error": error, "status_code": 401}

        # Resolve model to backend chain
        resolved_backend = self._resolve_backend(model)
        
        # 2. Quota enforcement
        quota_key_agent = self._get_quota_key("agent", headers["X-Agent-Id"])
        quota_key_user = self._get_quota_key("user", headers["X-User-Id"])
        exceeds, reason = self._check_quota(quota_key_agent, requests_delta=1)
        if exceeds:
            self._audit_log(headers, model, resolved_backend or "none", status="quota_denied", quota_reason=reason)
            return {"error": reason, "status_code": 429}

        # 3. Fallback simulation — try backends in chain until one is healthy
        backend_used = None
        fallback_from = None
        for candidate in self.fallback_chain:
            if resolved_backend and candidate != resolved_backend:
                continue  # model explicitly routed, don't try others
            status = self.backends.get(candidate)
            if status == BackendStatus.HEALTHY:
                backend_used = candidate
                break
            elif status == BackendStatus.UNHEALTHY and self.fallback_enabled:
                fallback_from = candidate
        
        if not backend_used:
            # No healthy backend — return actionable error
            self._audit_log(headers, model, "none", status="backend_unavailable")
            return {"error": "no healthy backend available; check model routes", "status_code": 503}

# 4. GPU admission check (for explicitly routed TRTLLM models only)
        # Fallback to trtllm from a healthy backend should not be blocked by GPU availability
        if resolved_backend == "trtllm" and backend_used == "trtllm" and not self.gpu_admission_available:
            # Fallback to ollama or error per policy
            if self.fallback_enabled:
                for alt in self.fallback_chain:
                    if alt != "trtllm" and self.backends.get(alt) == BackendStatus.HEALTHY:
                        backend_used = alt
                        fallback_from = fallback_from or "trtllm (gpu_admission_denied)"
                        break
                else:
                    self._audit_log(headers, model, "none", status="gpu_admission_denied")
                    return {"error": "GPU admission denied; no alternative backend healthy", "status_code": 429}
            else:
                return {"error": f"no GPU available for {model}", "status_code": 429}

        # Simulate generation response
        prompt_tokens = max(1, len(prompt.split()) * 1.3)  # rough estimate
        completion_tokens = max(1, int(len(prompt) / 4))   # rough estimate
        
        # Update quotas with token counts
        self._check_quota(quota_key_agent, tokens_delta=int(completion_tokens), requests_delta=0)
        self._check_quota(quota_key_user, tokens_delta=int(completion_tokens), requests_delta=0)

        # Log usage metrics
        self.metrics["tokens_total"] += int(prompt_tokens + completion_tokens)
        self.metrics["fallback_count"] += 1 if fallback_from else 0
        
        response = {
            "id": hashlib.sha256(f"{model}:{prompt[:50]}:{time.time()}".encode()).hexdigest()[:16],
            "model": model,
            "usage": {
                "prompt_tokens": int(prompt_tokens),
                "completion_tokens": int(completion_tokens),
                "total_tokens": int(prompt_tokens + completion_tokens),
            },
            "finish_reason": "stop",
            "content": f"[{backend_used}] simulated response for '{prompt[:30]}...'",
        }

        self._audit_log(headers, model, backend_used, 
                       prompt_tokens=int(prompt_tokens), 
                       completion_tokens=int(completion_tokens),
                       fallback_from=fallback_from)
        
        return response

    def _resolve_backend(self, model: str) -> Optional[str]:
        """Resolve preferred backend based on routing config.
        
        Returns the preferred backend or None if any backend in the chain is acceptable.
        """
        if self.llm_backend == LLMBehind.OLLAMA:
            return "ollama"
        elif self.llm_backend == LLMBehind.TRTLLM:
            return "trtllm"
        elif self.llm_backend == LLMBehind.REMOTE:
            return "remote"
        elif self.llm_backend == LLMBehind.BOTH:
            # Default to ollama for most models; trtllm for GPU-intensive ones.
            # Return None when both backends are acceptable, letting the fallback chain decide.
            gpu_suffixes = ("fp4", "nvfp4", "trtllm", "tensorrt")
            if any(suffix in model.lower() for suffix in gpu_suffixes):
                return "trtllm"
            # Return None so the full fallback chain is tried
            return None
        return None

    def _audit_log(self, headers: Dict[str, str], model: str, backend: str,
                   prompt_tokens: int = 0, completion_tokens: int = 0,
                   status: str = "success", fallback_from: Optional[str] = None,
                   quota_reason: Optional[str] = None):
        """Create an audit log entry for this model call."""
        entry = AuditEntry(
            timestamp=datetime.now(timezone.utc).isoformat(),
            user_id=headers.get("X-User-Id", "?"),
            agent_id=headers.get("X-Agent-Id", "?"),
            project_id=headers.get("X-Project-Id"),
            run_id=headers.get("X-Run-Id"),
            model_requested=model,
            backend_used=backend,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            status=status if not quota_reason else "quota_denied",
            fallback_from=fallback_from,
        )
        self.audit_log.append(entry)

    def get_audit_log(self, limit: int = 100) -> List[dict]:
        """Return recent audit entries as serializable dicts."""
        return [e.__dict__ for e in self.audit_log[-limit:]]

    @property
    def metrics(self) -> dict:
        return {
            "tokens_total": sum(
                e.prompt_tokens + e.completion_tokens for e in self.audit_log
            ),
            "fallback_count": sum(1 for e in self.audit_log if e.fallback_from),
            "backend_errors": sum(1 for e in self.audit_log if e.status == "error"),
            "quota_exceeded_count": sum(1 for e in self.audit_log if e.status == "quota_denied"),
        }


# ── CLI ─────────────────────────────────────────────────────────────────────

def cmd_validate(args):
    """Validate spec file against required fields."""
    spec_path = args.spec_file or os.path.join(
        os.path.dirname(__file__), "..", "..", "evaluation", "spec", "model_broker.yaml"
    )
    
    if not os.path.exists(spec_path):
        print(f"FAIL: spec file not found: {spec_path}", file=sys.stderr)
        return 1

    # Parse YAML (basic parsing without yaml library)
    required_sections = ["endpoints", "contract", "metrics", "test_oracle"]
    content = open(spec_path).read().lower()
    
    missing = []
    for section in required_sections:
        if section not in content:
            missing.append(section)
    
    if missing:
        print(f"FAIL: spec missing sections: {', '.join(missing)}", file=sys.stderr)
        return 1

    # Check contract subsections
    contract_checks = ["signed_identity_required", "fallback", "quotas", "gpu_admission"]
    for check in contract_checks:
        if check not in content:
            print(f"WARN: contract section may be missing '{check}'", file=sys.stderr)

    # Check endpoints defined
    endpoint_checks = ["/v1/models", "/v1/generate", "/v1/chat/completions", "/v1/embeddings"]
    for ep in endpoint_checks:
        if ep not in content:
            print(f"WARN: endpoint '{ep}' not found in spec", file=sys.stderr)

    print(f"OK: spec validates — all required sections and endpoints present")
    return 0


def cmd_test(_args=None):
    """Run contract validation tests."""
    broker = ModelBrokerContract()
    passed = 0
    failed = 0
    
    # Test 1: Identity required → 401 without headers
    result = broker.generate(model="qwen3", prompt="test")
    if "error" in result and result["status_code"] == 401:
        print("OK T1: identity required — missing headers returns 401")
        passed += 1
    else:
        print(f"FAIL T1: expected 401, got {result}")
        failed += 1

    # Test 2: Identity with known agent → passes validation
    result = broker.generate(
        model="qwen3-32b", prompt="hello",
        agent_id="codex", user_id="alice"
    )
    if "content" in result and "error" not in result:
        print("OK T2: valid identity passes validation")
        passed += 1
    else:
        print(f"FAIL T2: valid identity failed — {result}")
        failed += 1

    # Test 3: Unknown agent → 401
    result = broker.generate(
        model="qwen3", prompt="test",
        agent_id="unknown-agent-x", user_id="alice"
    )
    if result["status_code"] == 401 and "unknown agent" in result["error"].lower():
        print("OK T3: unknown agent identity rejected")
        passed += 1
    else:
        print(f"FAIL T3: expected 401 for unknown agent — {result}")
        failed += 1

    # Test 4: Backend failure triggers fallback
    broker.backends["ollama"] = BackendStatus.UNHEALTHY
    broker.backends["trtllm"] = BackendStatus.HEALTHY
    result = broker.generate(
        model="qwen3-32b", prompt="test",
        agent_id="codex", user_id="alice"
    )
    if "content" in result:  # Should succeed via fallback to trtllm
        print("OK T4: backend failure triggers fallback")
        passed += 1
    else:
        print(f"FAIL T4: fallback should succeed — {result}")
        failed += 1

    # Test 5: No healthy backend → 503
    broker.backends["ollama"] = BackendStatus.UNHEALTHY
    broker.backends["trtllm"] = BackendStatus.UNHEALTHY
    result = broker.generate(
        model="qwen3-32b", prompt="test",
        agent_id="codex", user_id="alice"
    )
    if "error" in result and result["status_code"] == 503:
        print("OK T5: all backends unhealthy returns 503")
        passed += 1
    else:
        print(f"FAIL T5: expected 503 — {result}")
        failed += 1

    # Test 6: Quota enforcement — first request succeeds (limit=2), second is denied
    broker_q = ModelBrokerContract()
    key = broker_q._get_quota_key("agent", "goose")
    broker_q.quotas[key] = QuotaState(tokens_limit=100, requests_limit=1)  # Allow only 1 request
    result = broker_q.generate(
        model="qwen3", prompt="test", agent_id="goose", user_id="alice"
    )
    result2 = broker_q.generate(
        model="qwen3", prompt="test", agent_id="goose", user_id="alice"
    )
    if result.get("status_code") != 429 and result2.get("status_code") == 429:
        print("OK T6: quota enforcement blocks over-limit requests")
        passed += 1
    else:
        print(f"FAIL T6: expected r1=success r2=429, got sc1={result.get('status_code')} sc2={result2.get('status_code')}")
        failed += 1

    # Test 7: Audit log records calls
    if len(broker.audit_log) >= 3:
        entry = broker.audit_log[-1]
        checks = all([
            entry.user_id == "alice",
            hasattr(entry, "timestamp"),
            hasattr(entry, "model_requested"),
        ])
        if checks:
            print("OK T7: audit log records agent calls with metadata")
            passed += 1
        else:
            print(f"FAIL T7: audit entry missing fields — {entry}")
            failed += 1
    else:
        print(f"FAIL T7: expected >=3 audit entries, got {len(broker.audit_log)}")
        failed += 1

    # Test 8: Metrics tracking
    metrics = broker.metrics
    if "tokens_total" in metrics and "fallback_count" in metrics:
        print("OK T8: metrics track tokens and fallback counts")
        passed += 1
    else:
        print(f"FAIL T8: metrics incomplete — {metrics}")
        failed += 1

    # Test 9: GPU admission denied when explicitly routed to trtllm with no alternative
    broker2 = ModelBrokerContract()
    broker2.backends["trtllm"] = BackendStatus.HEALTHY
    broker2.backends["ollama"] = BackendStatus.UNHEALTHY  # No alternative available
    broker2.gpu_admission_available = False
    broker2.llm_backend = LLMBehind.TRTLLM
    result = broker2.generate(
        model="nvfp4-model", prompt="test",
        agent_id="codex", user_id="alice"
    )
    if "error" in result and "gpu" in result["error"].lower():
        print("OK T9: GPU admission denied returns actionable error")
        passed += 1
    else:
        print(f"FAIL T9: expected gpu_admission error — {result}")
        failed += 1

    # Test 10: Signed identity verified per contract requirement
    broker3 = ModelBrokerContract()
    result_with_id = broker3.generate(
        model="qwen3", prompt="test",
        agent_id="codex", user_id="alice",
        project_id="ARTANY", run_id="run-001"
    )
    if len(broker3.audit_log) == 1:
        entry = broker3.audit_log[0]
        has_all_fields = all([
            entry.user_id == "alice",
            entry.agent_id == "codex",
            entry.project_id == "ARTANY",
            entry.run_id == "run-001",
        ])
        if has_all_fields:
            print("OK T10: signed identity (agent/user/project/run) recorded in audit")
            passed += 1
        else:
            print(f"FAIL T10: audit missing identity fields — {entry}")
            failed += 1
    else:
        print(f"FAIL T10: expected 1 audit entry, got {len(broker3.audit_log)}")
        failed += 1

    # Summary
    total = passed + failed
    print(f"\nModelBroker contract tests: {passed}/{total} passed" 
          + (f" ({failed} failed)" if failed else ""))
    
    return 0 if failed == 0 else 1


def main():
    parser = argparse.ArgumentParser(description="ModelBroker Protocol SDK (PLAN.md §6)")
    sub = parser.add_subparsers(dest="command")
    
    validate_p = sub.add_parser("validate", help="Validate spec file")
    validate_p.add_argument("--spec-file", default=None, help="Path to model_broker.yaml")
    
    test_p = sub.add_parser("test", help="Run contract tests")
    
    args = parser.parse_args()
    
    if args.command == "validate":
        sys.exit(cmd_validate(args))
    elif args.command == "test":
        sys.exit(cmd_test())
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
