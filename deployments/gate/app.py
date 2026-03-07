#!/usr/bin/env python3
import asyncio
import fnmatch
import hashlib
import json
import os
import re
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Tuple

import httpx
import yaml
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse, Response


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


ALLOWED_LLM_MODES = {"local", "hybrid", "remote"}


def normalize_llm_mode(raw: str | None, default: str = "hybrid") -> str:
    if isinstance(raw, str):
        candidate = raw.strip().lower()
        if candidate in ALLOWED_LLM_MODES:
            return candidate
    if default in ALLOWED_LLM_MODES:
        return default
    return "hybrid"


def parse_positive_int(value: Any) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return 0
    return parsed if parsed > 0 else 0


def utc_day_key() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def utc_month_key() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m")


class GateState:
    def __init__(self) -> None:
        self.ollama_base_url = os.getenv("OLLAMA_BASE_URL", "http://ollama:11434").rstrip("/")
        self.trtllm_base_url = os.getenv("TRTLLM_BASE_URL", "http://trtllm:11436").rstrip("/")
        self.model_routes_file = Path(os.getenv("GATE_MODEL_ROUTES_FILE", "/gate/config/model_routes.yml"))
        self.openai_api_key_file = os.getenv("GATE_OPENAI_API_KEY_FILE", "/gate/secrets/openai.api_key")
        self.openrouter_api_key_file = os.getenv(
            "GATE_OPENROUTER_API_KEY_FILE", "/gate/secrets/openrouter.api_key"
        )
        self.state_dir = Path(os.getenv("GATE_STATE_DIR", "/gate/state"))

        self.concurrency = max(1, env_int("GATE_CONCURRENCY", 1))
        self.default_queue_wait_timeout_seconds = max(
            0.1, env_float("GATE_QUEUE_WAIT_TIMEOUT_SECONDS", 2.0)
        )
        self.enable_test_mode = env_bool("GATE_ENABLE_TEST_MODE", False)
        self.max_test_sleep_seconds = max(0, env_int("GATE_MAX_TEST_SLEEP_SECONDS", 15))
        self.log_file = Path(os.getenv("GATE_LOG_FILE", "/gate/logs/gate.jsonl"))
        self.sticky_file = Path(
            os.getenv("GATE_STICKY_FILE", str(self.state_dir / "sticky_sessions.json"))
        )
        self.mode_file = Path(os.getenv("GATE_MODE_FILE", str(self.state_dir / "llm_mode.json")))
        self.quotas_file = Path(os.getenv("GATE_QUOTAS_FILE", str(self.state_dir / "quotas_state.json")))
        self.default_llm_mode = normalize_llm_mode(os.getenv("GATE_LLM_MODE", "hybrid"))
        self.llm_mode = self.default_llm_mode
        self._llm_mode_mtime = 0.0

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
        self.provider_quota_limits: Dict[str, Dict[str, int]] = {}
        self.quotas: Dict[str, Any] = {"version": 1, "providers": {}}
        self._quotas_dirty = False

        self.log_file.parent.mkdir(parents=True, exist_ok=True)
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.sticky_file.parent.mkdir(parents=True, exist_ok=True)
        self.mode_file.parent.mkdir(parents=True, exist_ok=True)
        self.quotas_file.parent.mkdir(parents=True, exist_ok=True)

        self._load_sticky()
        self._load_model_routes()
        self._load_mode()
        self._load_quotas()

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

    def _initial_quota_limits(self) -> Dict[str, Dict[str, int]]:
        return {
            "openai": {
                "daily_tokens": parse_positive_int(os.getenv("GATE_EXTERNAL_OPENAI_DAILY_TOKENS", "0")),
                "monthly_tokens": parse_positive_int(os.getenv("GATE_EXTERNAL_OPENAI_MONTHLY_TOKENS", "0")),
                "daily_requests": parse_positive_int(os.getenv("GATE_EXTERNAL_OPENAI_DAILY_REQUESTS", "0")),
                "monthly_requests": parse_positive_int(os.getenv("GATE_EXTERNAL_OPENAI_MONTHLY_REQUESTS", "0")),
            },
            "openrouter": {
                "daily_tokens": parse_positive_int(os.getenv("GATE_EXTERNAL_OPENROUTER_DAILY_TOKENS", "0")),
                "monthly_tokens": parse_positive_int(os.getenv("GATE_EXTERNAL_OPENROUTER_MONTHLY_TOKENS", "0")),
                "daily_requests": parse_positive_int(os.getenv("GATE_EXTERNAL_OPENROUTER_DAILY_REQUESTS", "0")),
                "monthly_requests": parse_positive_int(os.getenv("GATE_EXTERNAL_OPENROUTER_MONTHLY_REQUESTS", "0")),
            },
        }

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
        provider_quota_limits = self._initial_quota_limits()
        configured_default_mode = self.default_llm_mode

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

        llm_cfg = raw.get("llm") if isinstance(raw, dict) else None
        if isinstance(llm_cfg, dict):
            configured_default_mode = normalize_llm_mode(
                llm_cfg.get("default_mode"), default=configured_default_mode
            )

        quotas_cfg = raw.get("quotas") if isinstance(raw, dict) else None
        provider_cfg = quotas_cfg.get("providers") if isinstance(quotas_cfg, dict) else None
        if isinstance(provider_cfg, dict):
            for provider_name, provider_limits in provider_cfg.items():
                if not isinstance(provider_name, str) or not provider_name.strip():
                    continue
                if not isinstance(provider_limits, dict):
                    continue

                normalized_provider = provider_name.strip().lower()
                existing_limits = dict(provider_quota_limits.get(normalized_provider, {}))
                for field in ("daily_tokens", "monthly_tokens", "daily_requests", "monthly_requests"):
                    value = parse_positive_int(provider_limits.get(field))
                    if value > 0:
                        existing_limits[field] = value
                    elif field not in existing_limits:
                        existing_limits[field] = 0
                provider_quota_limits[normalized_provider] = existing_limits

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
        self.provider_quota_limits = provider_quota_limits
        self.default_llm_mode = configured_default_mode

    def _read_mode_file(self) -> str:
        if not self.mode_file.exists():
            return self.default_llm_mode
        try:
            raw = json.loads(self.mode_file.read_text(encoding="utf-8"))
        except Exception:
            return self.default_llm_mode

        if isinstance(raw, dict):
            return normalize_llm_mode(raw.get("mode"), default=self.default_llm_mode)
        if isinstance(raw, str):
            return normalize_llm_mode(raw, default=self.default_llm_mode)
        return self.default_llm_mode

    def _load_mode(self) -> None:
        self.llm_mode = self._read_mode_file()
        try:
            self._llm_mode_mtime = self.mode_file.stat().st_mtime
        except FileNotFoundError:
            self._llm_mode_mtime = 0.0

    def refresh_mode_if_needed(self) -> None:
        try:
            mode_mtime = self.mode_file.stat().st_mtime
        except FileNotFoundError:
            mode_mtime = 0.0

        if mode_mtime == self._llm_mode_mtime:
            return
        self._load_mode()

    def get_llm_mode(self) -> str:
        self.refresh_mode_if_needed()
        return self.llm_mode

    def persist_llm_mode(self, mode: str, actor: str) -> str:
        normalized = normalize_llm_mode(mode, default=self.default_llm_mode)
        payload = {
            "mode": normalized,
            "updated_at": now_iso(),
            "updated_by": actor if isinstance(actor, str) and actor.strip() else "api",
        }
        tmp = self.mode_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
        os.replace(tmp, self.mode_file)
        self._load_mode()
        return self.llm_mode

    def _blank_window(self, period: str) -> Dict[str, Any]:
        return {"period": period, "requests": 0, "tokens": 0}

    def _ensure_provider_quota(self, provider: str) -> Dict[str, Any]:
        providers = self.quotas.setdefault("providers", {})
        entry = providers.get(provider)
        if not isinstance(entry, dict):
            entry = {}
            providers[provider] = entry

        totals = entry.get("totals")
        if not isinstance(totals, dict):
            totals = {"requests": 0, "tokens": 0, "denied": 0}
            entry["totals"] = totals
        for field in ("requests", "tokens", "denied"):
            totals[field] = parse_positive_int(totals.get(field, 0))

        daily = entry.get("daily")
        if not isinstance(daily, dict):
            daily = self._blank_window(utc_day_key())
            entry["daily"] = daily
        else:
            daily["period"] = str(daily.get("period", utc_day_key()))
            daily["requests"] = parse_positive_int(daily.get("requests", 0))
            daily["tokens"] = parse_positive_int(daily.get("tokens", 0))

        monthly = entry.get("monthly")
        if not isinstance(monthly, dict):
            monthly = self._blank_window(utc_month_key())
            entry["monthly"] = monthly
        else:
            monthly["period"] = str(monthly.get("period", utc_month_key()))
            monthly["requests"] = parse_positive_int(monthly.get("requests", 0))
            monthly["tokens"] = parse_positive_int(monthly.get("tokens", 0))

        projects = entry.get("projects")
        if not isinstance(projects, dict):
            projects = {}
            entry["projects"] = projects

        return entry

    def _ensure_project_quota(self, provider_entry: Dict[str, Any], project: str) -> Dict[str, Any]:
        projects = provider_entry.setdefault("projects", {})
        project_entry = projects.get(project)
        if not isinstance(project_entry, dict):
            project_entry = {
                "totals": {"requests": 0, "tokens": 0},
                "daily": self._blank_window(utc_day_key()),
                "monthly": self._blank_window(utc_month_key()),
            }
            projects[project] = project_entry

        totals = project_entry.setdefault("totals", {})
        totals["requests"] = parse_positive_int(totals.get("requests", 0))
        totals["tokens"] = parse_positive_int(totals.get("tokens", 0))

        for window_name, period in (("daily", utc_day_key()), ("monthly", utc_month_key())):
            window = project_entry.get(window_name)
            if not isinstance(window, dict):
                window = self._blank_window(period)
                project_entry[window_name] = window
            if str(window.get("period")) != period:
                window["period"] = period
                window["requests"] = 0
                window["tokens"] = 0
            window["requests"] = parse_positive_int(window.get("requests", 0))
            window["tokens"] = parse_positive_int(window.get("tokens", 0))

        return project_entry

    def _rollover_quota_windows(self, provider_entry: Dict[str, Any]) -> bool:
        changed = False
        current_day = utc_day_key()
        current_month = utc_month_key()

        daily = provider_entry.get("daily")
        if not isinstance(daily, dict):
            provider_entry["daily"] = self._blank_window(current_day)
            changed = True
        elif str(daily.get("period")) != current_day:
            provider_entry["daily"] = self._blank_window(current_day)
            changed = True

        monthly = provider_entry.get("monthly")
        if not isinstance(monthly, dict):
            provider_entry["monthly"] = self._blank_window(current_month)
            changed = True
        elif str(monthly.get("period")) != current_month:
            provider_entry["monthly"] = self._blank_window(current_month)
            changed = True

        projects = provider_entry.get("projects")
        if isinstance(projects, dict):
            for project_entry in projects.values():
                if not isinstance(project_entry, dict):
                    continue
                for window_name, period in (("daily", current_day), ("monthly", current_month)):
                    window = project_entry.get(window_name)
                    if not isinstance(window, dict) or str(window.get("period")) != period:
                        project_entry[window_name] = self._blank_window(period)
                        changed = True
                        continue
                    requests_count = parse_positive_int(window.get("requests", 0))
                    tokens_count = parse_positive_int(window.get("tokens", 0))
                    if requests_count != window.get("requests") or tokens_count != window.get("tokens"):
                        changed = True
                    window["requests"] = requests_count
                    window["tokens"] = tokens_count

        return changed

    def _load_quotas(self) -> None:
        if not self.quotas_file.exists():
            self.quotas = {"version": 1, "providers": {}}
            return
        try:
            raw = json.loads(self.quotas_file.read_text(encoding="utf-8"))
        except Exception:
            self.quotas = {"version": 1, "providers": {}}
            return
        if isinstance(raw, dict):
            self.quotas = raw
        else:
            self.quotas = {"version": 1, "providers": {}}

    def _save_quotas(self) -> None:
        tmp = self.quotas_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.quotas, sort_keys=True), encoding="utf-8")
        os.replace(tmp, self.quotas_file)

    async def flush_quotas_if_dirty(self) -> None:
        async with self.lock:
            if not self._quotas_dirty:
                return
            self._quotas_dirty = False
        self._save_quotas()

    async def external_quota_precheck(
        self, provider: str, project: str, estimated_tokens: int
    ) -> tuple[bool, Dict[str, Any]]:
        provider_norm = provider.strip().lower()
        limits = dict(self.provider_quota_limits.get(provider_norm, {}))
        if not any(parse_positive_int(value) > 0 for value in limits.values()):
            return True, {"remaining": {}}

        estimated = max(0, estimated_tokens)
        detail: Dict[str, Any] = {}
        should_flush = False
        async with self.lock:
            provider_entry = self._ensure_provider_quota(provider_norm)
            project_key = project if isinstance(project, str) and project.strip() else "-"
            self._ensure_project_quota(provider_entry, project_key)
            if self._rollover_quota_windows(provider_entry):
                self._quotas_dirty = True
                should_flush = True

            daily = provider_entry["daily"]
            monthly = provider_entry["monthly"]
            denied_reason = ""

            if parse_positive_int(limits.get("daily_requests", 0)) > 0 and (
                daily["requests"] + 1 > parse_positive_int(limits["daily_requests"])
            ):
                denied_reason = "daily_requests_quota_exceeded"
            elif parse_positive_int(limits.get("monthly_requests", 0)) > 0 and (
                monthly["requests"] + 1 > parse_positive_int(limits["monthly_requests"])
            ):
                denied_reason = "monthly_requests_quota_exceeded"
            elif estimated > 0 and parse_positive_int(limits.get("daily_tokens", 0)) > 0 and (
                daily["tokens"] + estimated > parse_positive_int(limits["daily_tokens"])
            ):
                denied_reason = "daily_tokens_quota_exceeded"
            elif estimated > 0 and parse_positive_int(limits.get("monthly_tokens", 0)) > 0 and (
                monthly["tokens"] + estimated > parse_positive_int(limits["monthly_tokens"])
            ):
                denied_reason = "monthly_tokens_quota_exceeded"

            remaining = {
                "daily_tokens": (
                    parse_positive_int(limits["daily_tokens"]) - daily["tokens"]
                    if parse_positive_int(limits.get("daily_tokens", 0)) > 0
                    else -1
                ),
                "monthly_tokens": (
                    parse_positive_int(limits["monthly_tokens"]) - monthly["tokens"]
                    if parse_positive_int(limits.get("monthly_tokens", 0)) > 0
                    else -1
                ),
                "daily_requests": (
                    parse_positive_int(limits["daily_requests"]) - daily["requests"]
                    if parse_positive_int(limits.get("daily_requests", 0)) > 0
                    else -1
                ),
                "monthly_requests": (
                    parse_positive_int(limits["monthly_requests"]) - monthly["requests"]
                    if parse_positive_int(limits.get("monthly_requests", 0)) > 0
                    else -1
                ),
            }

            if denied_reason:
                provider_entry["totals"]["denied"] = parse_positive_int(provider_entry["totals"].get("denied", 0)) + 1
                self._quotas_dirty = True
                should_flush = True
                detail = {"reason": denied_reason, "remaining": remaining, "limits": limits}
                allowed = False
            else:
                detail = {"remaining": remaining, "limits": limits}
                allowed = True

        if should_flush:
            await self.flush_quotas_if_dirty()
        return allowed, detail

    async def external_quota_record(self, provider: str, project: str, tokens: int) -> None:
        provider_norm = provider.strip().lower()
        token_count = max(0, tokens)
        async with self.lock:
            provider_entry = self._ensure_provider_quota(provider_norm)
            project_key = project if isinstance(project, str) and project.strip() else "-"
            project_entry = self._ensure_project_quota(provider_entry, project_key)
            self._rollover_quota_windows(provider_entry)

            provider_entry["totals"]["requests"] = parse_positive_int(provider_entry["totals"].get("requests", 0)) + 1
            provider_entry["totals"]["tokens"] = parse_positive_int(provider_entry["totals"].get("tokens", 0)) + token_count
            provider_entry["daily"]["requests"] = parse_positive_int(provider_entry["daily"].get("requests", 0)) + 1
            provider_entry["daily"]["tokens"] = parse_positive_int(provider_entry["daily"].get("tokens", 0)) + token_count
            provider_entry["monthly"]["requests"] = parse_positive_int(provider_entry["monthly"].get("requests", 0)) + 1
            provider_entry["monthly"]["tokens"] = parse_positive_int(provider_entry["monthly"].get("tokens", 0)) + token_count

            project_entry["totals"]["requests"] = parse_positive_int(project_entry["totals"].get("requests", 0)) + 1
            project_entry["totals"]["tokens"] = parse_positive_int(project_entry["totals"].get("tokens", 0)) + token_count
            project_entry["daily"]["requests"] = parse_positive_int(project_entry["daily"].get("requests", 0)) + 1
            project_entry["daily"]["tokens"] = parse_positive_int(project_entry["daily"].get("tokens", 0)) + token_count
            project_entry["monthly"]["requests"] = parse_positive_int(project_entry["monthly"].get("requests", 0)) + 1
            project_entry["monthly"]["tokens"] = parse_positive_int(project_entry["monthly"].get("tokens", 0)) + token_count

            self._quotas_dirty = True
        await self.flush_quotas_if_dirty()

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

    async def snapshot_external_metrics(self) -> Dict[str, Dict[str, int]]:
        snapshot: Dict[str, Dict[str, int]] = {}
        should_flush = False
        async with self.lock:
            providers_raw = self.quotas.get("providers", {})
            known_providers = set(self.provider_quota_limits.keys())
            if isinstance(providers_raw, dict):
                known_providers.update(str(provider) for provider in providers_raw.keys())

            for provider in sorted(item.strip().lower() for item in known_providers if str(item).strip()):
                provider_entry = self._ensure_provider_quota(provider)
                if self._rollover_quota_windows(provider_entry):
                    self._quotas_dirty = True
                    should_flush = True

                limits = dict(self.provider_quota_limits.get(provider, {}))
                daily = provider_entry["daily"]
                monthly = provider_entry["monthly"]
                totals = provider_entry["totals"]

                daily_tokens_limit = parse_positive_int(limits.get("daily_tokens", 0))
                monthly_tokens_limit = parse_positive_int(limits.get("monthly_tokens", 0))
                daily_requests_limit = parse_positive_int(limits.get("daily_requests", 0))
                monthly_requests_limit = parse_positive_int(limits.get("monthly_requests", 0))

                snapshot[provider] = {
                    "requests_total": parse_positive_int(totals.get("requests", 0)),
                    "tokens_total": parse_positive_int(totals.get("tokens", 0)),
                    "denied_total": parse_positive_int(totals.get("denied", 0)),
                    "remaining_daily_tokens": (
                        daily_tokens_limit - parse_positive_int(daily.get("tokens", 0))
                        if daily_tokens_limit > 0
                        else -1
                    ),
                    "remaining_monthly_tokens": (
                        monthly_tokens_limit - parse_positive_int(monthly.get("tokens", 0))
                        if monthly_tokens_limit > 0
                        else -1
                    ),
                    "remaining_daily_requests": (
                        daily_requests_limit - parse_positive_int(daily.get("requests", 0))
                        if daily_requests_limit > 0
                        else -1
                    ),
                    "remaining_monthly_requests": (
                        monthly_requests_limit - parse_positive_int(monthly.get("requests", 0))
                        if monthly_requests_limit > 0
                        else -1
                    ),
                }

        if should_flush:
            await self.flush_quotas_if_dirty()
        return snapshot

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


def provider_is_external(provider: str | None) -> bool:
    if not isinstance(provider, str):
        return False
    return provider.strip().lower() not in ("", "local")


def extract_test_tokens(request: Request) -> int:
    raw = request.headers.get("X-Gate-Test-Tokens", "0")
    try:
        value = int(raw)
    except ValueError:
        return 0
    return max(0, value)


def parse_non_negative_int(value: Any) -> int | None:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return None
    if parsed < 0:
        return None
    return parsed


def parse_normalized_usage(value: Any) -> Dict[str, int] | None:
    if not isinstance(value, dict):
        return None

    input_tokens = parse_non_negative_int(value.get("input_tokens"))
    if input_tokens is None:
        input_tokens = parse_non_negative_int(value.get("prompt_tokens"))

    output_tokens = parse_non_negative_int(value.get("output_tokens"))
    if output_tokens is None:
        output_tokens = parse_non_negative_int(value.get("completion_tokens"))

    total_tokens = parse_non_negative_int(value.get("total_tokens"))

    if input_tokens is None and output_tokens is None and total_tokens is None:
        return None

    if input_tokens is None and total_tokens is not None and output_tokens is not None:
        input_tokens = max(0, total_tokens - output_tokens)
    if output_tokens is None and total_tokens is not None and input_tokens is not None:
        output_tokens = max(0, total_tokens - input_tokens)

    if input_tokens is None:
        input_tokens = 0
    if output_tokens is None:
        output_tokens = 0
    if total_tokens is None:
        total_tokens = input_tokens + output_tokens

    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": total_tokens,
    }


def extract_usage_from_upstream(protocol: str, payload: Dict[str, Any]) -> Dict[str, int] | None:
    if not isinstance(payload, dict):
        return None

    usage = parse_normalized_usage(payload.get("usage"))
    if usage is not None:
        return usage

    input_tokens = parse_non_negative_int(payload.get("prompt_eval_count"))
    output_tokens = parse_non_negative_int(payload.get("eval_count"))
    total_tokens = parse_non_negative_int(payload.get("total_tokens"))
    if input_tokens is None and output_tokens is None and total_tokens is None:
        return None

    if input_tokens is None and total_tokens is not None and output_tokens is not None:
        input_tokens = max(0, total_tokens - output_tokens)
    if output_tokens is None and total_tokens is not None and input_tokens is not None:
        output_tokens = max(0, total_tokens - input_tokens)
    if input_tokens is None:
        input_tokens = 0
    if output_tokens is None:
        output_tokens = 0
    if total_tokens is None:
        total_tokens = input_tokens + output_tokens

    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": total_tokens,
    }


def extract_total_tokens(payload: Dict[str, Any]) -> int:
    usage = extract_usage_from_upstream("", payload)
    if usage is None:
        return 0
    return usage["total_tokens"]


def extract_requested_model(payload: Any) -> str | None:
    if not isinstance(payload, dict):
        return None

    model = payload.get("model")
    if isinstance(model, str) and model.strip():
        return model.strip()

    name = payload.get("name")
    if isinstance(name, str) and name.strip():
        return name.strip()

    return None


def gate_response_headers(
    decision: str,
    backend: str,
    provider: str,
    llm_mode: str,
    model_served: str | None = None,
) -> Dict[str, str]:
    headers = {
        "X-Gate-Decision": decision,
        "X-Gate-Backend": backend,
        "X-Gate-Provider": provider,
        "X-Gate-LLM-Mode": llm_mode,
    }
    if isinstance(model_served, str) and model_served:
        headers["X-Model-Served"] = model_served
    return headers


def upstream_response_with_gate_headers(
    upstream: httpx.Response,
    decision: str,
    backend: str,
    provider: str,
    llm_mode: str,
    model_served: str | None = None,
) -> Response:
    headers = gate_response_headers(
        decision=decision,
        backend=backend,
        provider=provider,
        llm_mode=llm_mode,
        model_served=model_served,
    )
    content_type = upstream.headers.get("content-type")
    if isinstance(content_type, str) and content_type:
        headers["Content-Type"] = content_type
    return Response(status_code=upstream.status_code, content=upstream.content, headers=headers)


def llm_mode_block_response(provider: str, endpoint: str, llm_mode: str) -> JSONResponse:
    return JSONResponse(
        status_code=403,
        content={
            "error": {
                "message": (
                    f"provider '{provider}' is disabled while gate is in llm_mode='{llm_mode}'. "
                    "Switch to 'hybrid' or 'remote' to allow external providers."
                ),
                "type": "external_provider_disabled",
                "provider": provider,
                "endpoint": endpoint,
                "llm_mode": llm_mode,
            }
        },
    )


def quota_exceeded_response(provider: str, detail: Dict[str, Any]) -> JSONResponse:
    reason = str(detail.get("reason", "external_quota_exceeded"))
    return JSONResponse(
        status_code=429,
        content={
            "error": {
                "message": (
                    f"external provider quota exceeded for '{provider}' "
                    f"(reason={reason}); adjust gate quotas or wait for window reset."
                ),
                "type": "external_quota_exceeded",
                "provider": provider,
                "reason": reason,
                "remaining": detail.get("remaining", {}),
                "limits": detail.get("limits", {}),
            }
        },
    )


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


def parse_iso_to_unix_seconds(value: Any) -> int | None:
    if not isinstance(value, str):
        return None
    candidate = value.strip()
    if not candidate:
        return None
    if candidate.endswith("Z"):
        candidate = f"{candidate[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return int(parsed.timestamp())


def normalize_ollama_model_record(item: Dict[str, Any], backend: str, provider: str) -> Dict[str, Any] | None:
    name = item.get("name")
    if not isinstance(name, str) or not name:
        return None

    record: Dict[str, Any] = {"id": name, "object": "model", "owned_by": "ollama-gate"}
    created = parse_iso_to_unix_seconds(item.get("modified_at"))
    if created is not None:
        record["created"] = created

    metadata: Dict[str, Any] = {"backend": backend, "provider": provider, "source": "ollama:/api/tags"}
    digest = item.get("digest")
    if isinstance(digest, str) and digest:
        metadata["digest"] = digest
    size = item.get("size")
    if isinstance(size, int) and size >= 0:
        metadata["size_bytes"] = size
    modified_at = item.get("modified_at")
    if isinstance(modified_at, str) and modified_at:
        metadata["modified_at"] = modified_at

    details = item.get("details")
    if isinstance(details, dict):
        family = details.get("family")
        if isinstance(family, str) and family:
            metadata["family"] = family
        families = details.get("families")
        if isinstance(families, list):
            normalized_families = [entry for entry in families if isinstance(entry, str) and entry]
            if normalized_families:
                metadata["families"] = normalized_families
        parameter_size = details.get("parameter_size")
        if isinstance(parameter_size, str) and parameter_size:
            metadata["parameter_size"] = parameter_size
        quantization_level = details.get("quantization_level")
        if isinstance(quantization_level, str) and quantization_level:
            metadata["quantization_level"] = quantization_level
        fmt = details.get("format")
        if isinstance(fmt, str) and fmt:
            metadata["format"] = fmt
        parent_model = details.get("parent_model")
        if isinstance(parent_model, str) and parent_model:
            metadata["parent_model"] = parent_model

    record["metadata"] = metadata
    return record


def normalize_openai_model_record(item: Dict[str, Any], backend: str, provider: str) -> Dict[str, Any] | None:
    name = item.get("id")
    if not isinstance(name, str) or not name:
        return None

    owned_by = item.get("owned_by")
    if not isinstance(owned_by, str) or not owned_by:
        owned_by = "ollama-gate"
    record: Dict[str, Any] = {"id": name, "object": "model", "owned_by": owned_by}

    created = item.get("created")
    if isinstance(created, int) and created > 0:
        record["created"] = created
    elif isinstance(created, str):
        normalized_created = parse_iso_to_unix_seconds(created)
        if normalized_created is not None:
            record["created"] = normalized_created

    record["metadata"] = {"backend": backend, "provider": provider, "source": "openai:/models"}
    return record


async def fetch_backend_model_catalog(backend: str) -> list[Dict[str, Any]]:
    cfg = state.backend_config(backend)
    if cfg is None:
        return []

    provider = backend_provider_name(backend)
    if cfg["protocol"] == "ollama":
        async with httpx.AsyncClient(timeout=10, trust_env=True) as client:
            resp = await client.get(f"{cfg['base_url']}/api/tags")
            resp.raise_for_status()
            payload = resp.json()

        models = payload.get("models", [])
        records: list[Dict[str, Any]] = []
        if isinstance(models, list):
            for item in models:
                if isinstance(item, dict):
                    record = normalize_ollama_model_record(item, backend=backend, provider=provider)
                    if record is not None:
                        records.append(record)
        return records

    if cfg["protocol"] == "openai":
        api_key = resolve_backend_api_key(backend, cfg)
        headers = backend_request_headers(cfg, api_key)
        async with httpx.AsyncClient(timeout=15, trust_env=True) as client:
            resp = await client.get(f"{cfg['base_url']}/models", headers=headers)
            resp.raise_for_status()
            payload = resp.json()

        models = payload.get("data")
        records: list[Dict[str, Any]] = []
        if isinstance(models, list):
            for item in models:
                if isinstance(item, dict):
                    record = normalize_openai_model_record(item, backend=backend, provider=provider)
                    if record is not None:
                        records.append(record)
        return records

    return []


async def fetch_backend_models(backend: str) -> list[str]:
    records = await fetch_backend_model_catalog(backend)
    names: list[str] = []
    for record in records:
        name = record.get("id")
        if isinstance(name, str) and name:
            names.append(name)
    return names


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
    llm_mode: str | None = None,
    external_tokens: int | None = None,
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
        "llm_mode": llm_mode,
        "external_tokens": external_tokens,
    }


@app.get("/healthz")
async def healthz() -> Dict[str, str]:
    return {"status": "ok"}


@app.get("/metrics")
async def metrics() -> PlainTextResponse:
    m = await state.snapshot_metrics()
    llm_mode = state.get_llm_mode()
    external = await state.snapshot_external_metrics()
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
        "# TYPE gate_llm_mode gauge",
        f"gate_llm_mode{{mode=\"{llm_mode}\"}} 1",
    ]
    for provider, stats in external.items():
        lines.extend(
            [
                "# TYPE external_requests_total counter",
                f"external_requests_total{{provider=\"{provider}\"}} {stats['requests_total']}",
                "# TYPE external_tokens_total counter",
                f"external_tokens_total{{provider=\"{provider}\"}} {stats['tokens_total']}",
                "# TYPE external_quota_denied_total counter",
                f"external_quota_denied_total{{provider=\"{provider}\"}} {stats['denied_total']}",
                "# TYPE external_quota_remaining gauge",
                (
                    f"external_quota_remaining{{provider=\"{provider}\",window=\"daily_tokens\"}} "
                    f"{stats['remaining_daily_tokens']}"
                ),
                (
                    f"external_quota_remaining{{provider=\"{provider}\",window=\"monthly_tokens\"}} "
                    f"{stats['remaining_monthly_tokens']}"
                ),
                (
                    f"external_quota_remaining{{provider=\"{provider}\",window=\"daily_requests\"}} "
                    f"{stats['remaining_daily_requests']}"
                ),
                (
                    f"external_quota_remaining{{provider=\"{provider}\",window=\"monthly_requests\"}} "
                    f"{stats['remaining_monthly_requests']}"
                ),
            ]
        )
    return PlainTextResponse("\n".join(lines) + "\n")


async def read_json_body(request: Request) -> tuple[Dict[str, Any] | None, JSONResponse | None]:
    try:
        payload = await request.json()
    except Exception:
        return None, JSONResponse(
            status_code=400,
            content={"error": {"message": "invalid JSON body", "type": "invalid_request_error"}},
        )

    if not isinstance(payload, dict):
        return None, JSONResponse(
            status_code=400,
            content={"error": {"message": "JSON body must be an object", "type": "invalid_request_error"}},
        )
    return payload, None


async def proxy_ollama_api(
    request: Request,
    endpoint: str,
    payload: Dict[str, Any] | None,
    session_default: str,
    sticky_model: bool = False,
) -> Response:
    queue_wait_timeout_seconds = extract_queue_timeout_seconds(request)
    session = request.headers.get("X-Agent-Session", session_default)
    project = request.headers.get("X-Agent-Project", "-")
    llm_mode = state.get_llm_mode()
    allow_switch = header_bool(request.headers.get("X-Model-Switch"))
    started = time.monotonic()
    acquired = False
    decision = "active"
    requested_model = extract_requested_model(payload)
    model_served = requested_model
    model_switch = False
    backend = state.default_backend
    provider = backend_provider_name(backend)
    status_code = 200
    reason = None

    try:
        decision, acquired = await acquire_gate_slot(queue_wait_timeout_seconds)
    except asyncio.TimeoutError:
        latency_ms = int((time.monotonic() - started) * 1000)
        await state.mark_decision("denied")
        state.write_log(
            event_base(
                session=session,
                project=project,
                endpoint=endpoint,
                decision="denied",
                model_requested=requested_model,
                model_served=None,
                status_code=429,
                latency_ms=latency_ms,
                backend=backend,
                provider=provider,
                reason="queue_timeout",
                llm_mode=llm_mode,
            )
        )
        return JSONResponse(
            status_code=429,
            content={"error": {"message": "queue timeout", "type": "queue_timeout", "decision": "denied"}},
        )

    try:
        if sticky_model and endpoint in ("/api/chat", "/api/generate", "/api/embeddings"):
            model_served, model_switch = await resolve_model(
                session=session,
                requested=requested_model,
                allow_switch=allow_switch,
            )

        backend = state.resolve_backend(model_served)
        provider = backend_provider_name(backend)
        llm_mode = state.get_llm_mode()

        cfg = state.backend_config(backend)
        if cfg is None:
            status_code = 500
            reason = "backend_config_error"
            return JSONResponse(
                status_code=500,
                content={
                    "error": {
                        "message": f"backend '{backend}' is not configured",
                        "type": "backend_config_error",
                        "backend": backend,
                        "provider": provider,
                    }
                },
            )

        if cfg["protocol"] != "ollama":
            status_code = 501
            reason = "ollama_api_unsupported_backend_protocol"
            return JSONResponse(
                status_code=501,
                content={
                    "error": {
                        "message": (
                            f"backend '{backend}' uses protocol '{cfg['protocol']}' and cannot serve native "
                            f"endpoint '{endpoint}'. Use /v1/* for this model/backend."
                        ),
                        "type": "unsupported_backend_protocol",
                        "backend": backend,
                        "provider": provider,
                    }
                },
            )

        upstream_payload = payload
        if isinstance(upstream_payload, dict) and isinstance(model_served, str) and model_served:
            if "model" in upstream_payload and upstream_payload.get("model") != model_served:
                upstream_payload = dict(upstream_payload)
                upstream_payload["model"] = model_served
            elif "name" in upstream_payload and upstream_payload.get("name") != model_served:
                upstream_payload = dict(upstream_payload)
                upstream_payload["name"] = model_served

        try:
            async with httpx.AsyncClient(timeout=90, trust_env=True) as client:
                upstream = await client.request(
                    request.method,
                    f"{cfg['base_url']}{endpoint}",
                    json=upstream_payload,
                    params=dict(request.query_params),
                )
        except httpx.RequestError as exc:
            status_code = 503
            reason = "backend_unavailable"
            return backend_unavailable_response(backend, model_served or "unknown", str(exc))

        status_code = upstream.status_code
        if upstream.status_code >= 500 and backend == "trtllm":
            reason = "backend_unavailable"
            detail = upstream.text
            return backend_unavailable_response(
                backend,
                model_served or "unknown",
                f"HTTP {upstream.status_code}: {detail[:300]}",
            )

        return upstream_response_with_gate_headers(
            upstream=upstream,
            decision=decision,
            backend=backend,
            provider=provider,
            llm_mode=llm_mode,
            model_served=model_served,
        )
    finally:
        await release_gate_slot(acquired)
        await state.mark_decision("denied" if status_code == 429 else decision)
        latency_ms = int((time.monotonic() - started) * 1000)
        state.write_log(
            event_base(
                session=session,
                project=project,
                endpoint=endpoint,
                decision="denied" if status_code == 429 else decision,
                model_requested=requested_model,
                model_served=model_served,
                status_code=status_code,
                latency_ms=latency_ms,
                backend=backend,
                provider=provider,
                model_switch=model_switch,
                reason=reason,
                llm_mode=llm_mode,
            )
        )


@app.get("/api/version")
async def api_version(request: Request) -> Response:
    return await proxy_ollama_api(
        request=request,
        endpoint="/api/version",
        payload=None,
        session_default="version",
        sticky_model=False,
    )


@app.get("/api/tags")
async def api_tags(request: Request) -> Response:
    return await proxy_ollama_api(
        request=request,
        endpoint="/api/tags",
        payload=None,
        session_default="models-list",
        sticky_model=False,
    )


@app.post("/api/show")
async def api_show(request: Request) -> Response:
    payload, error = await read_json_body(request)
    if error is not None:
        return error
    return await proxy_ollama_api(
        request=request,
        endpoint="/api/show",
        payload=payload,
        session_default="show",
        sticky_model=False,
    )


@app.post("/api/generate")
async def api_generate(request: Request) -> Response:
    payload, error = await read_json_body(request)
    if error is not None:
        return error
    return await proxy_ollama_api(
        request=request,
        endpoint="/api/generate",
        payload=payload,
        session_default="generate",
        sticky_model=True,
    )


@app.post("/api/chat")
async def api_chat(request: Request) -> Response:
    payload, error = await read_json_body(request)
    if error is not None:
        return error
    return await proxy_ollama_api(
        request=request,
        endpoint="/api/chat",
        payload=payload,
        session_default="chat",
        sticky_model=True,
    )


@app.post("/api/embeddings")
async def api_embeddings_ollama(request: Request) -> Response:
    payload, error = await read_json_body(request)
    if error is not None:
        return error
    return await proxy_ollama_api(
        request=request,
        endpoint="/api/embeddings",
        payload=payload,
        session_default="embeddings",
        sticky_model=True,
    )


@app.get("/v1/models")
async def v1_models(request: Request) -> JSONResponse:
    queue_wait_timeout_seconds = extract_queue_timeout_seconds(request)
    session = request.headers.get("X-Agent-Session", "models-list")
    project = request.headers.get("X-Agent-Project", "-")
    llm_mode = state.get_llm_mode()
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
                llm_mode=llm_mode,
            )
        )
        return JSONResponse(
            status_code=429,
            content={"error": {"message": "queue timeout", "type": "queue_timeout", "decision": "denied"}},
        )

    status_code = 200
    reason = None
    try:
        provider = backend_provider_name(backend)
        if llm_mode == "local" and provider_is_external(provider):
            status_code = 403
            reason = "external_provider_disabled"
            return llm_mode_block_response(provider, "/v1/models", llm_mode)
        records = await fetch_backend_model_catalog(backend)
        response = {
            "object": "list",
            "data": records,
        }
        return JSONResponse(
            status_code=200,
            content=response,
            headers={
                "X-Gate-Decision": decision,
                "X-Gate-Backend": backend,
                "X-Gate-Provider": provider,
                "X-Gate-LLM-Mode": llm_mode,
            },
        )
    except BackendAuthError as exc:
        status_code = 503
        reason = "backend_auth_error"
        return backend_auth_response(backend, provider, str(exc))
    except Exception as exc:
        status_code = 502
        reason = "upstream_error"
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
                reason=reason,
                llm_mode=llm_mode,
            )
        )


async def backend_chat_completion(
    backend: str,
    model: str,
    messages: Any,
    *,
    tools: Any = None,
    tool_choice: Any = None,
) -> tuple[int, dict[str, Any], str]:
    cfg = state.backend_config(backend)
    if cfg is None:
        raise RuntimeError(f"backend '{backend}' is not configured")

    protocol = cfg["protocol"]

    if protocol == "ollama":
        use_openai_compat = isinstance(tools, list) or tool_choice is not None
        upstream_payload: Dict[str, Any] = {
            "model": model,
            "messages": messages if isinstance(messages, list) else [],
            "stream": False,
        }
        if isinstance(tools, list):
            upstream_payload["tools"] = tools
        if isinstance(tool_choice, (str, dict)):
            upstream_payload["tool_choice"] = tool_choice

        try:
            async with httpx.AsyncClient(timeout=60, trust_env=True) as client:
                upstream = await client.post(
                    f"{cfg['base_url']}/v1/chat/completions" if use_openai_compat else f"{cfg['base_url']}/api/chat",
                    json=upstream_payload,
                )
        except httpx.RequestError as exc:
            raise ConnectionError(str(exc)) from exc

        text = upstream.text
        if upstream.status_code >= 400:
            return upstream.status_code, {}, text

        return upstream.status_code, upstream.json(), text

    if protocol == "openai":
        api_key = resolve_backend_api_key(backend, cfg)
        upstream_payload: Dict[str, Any] = {
            "model": model,
            "messages": messages if isinstance(messages, list) else [],
            "stream": False,
        }
        if isinstance(tools, list):
            upstream_payload["tools"] = tools
        if isinstance(tool_choice, (str, dict)):
            upstream_payload["tool_choice"] = tool_choice
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


def json_dumps_compact(value: Any) -> str:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"))


def normalize_tool_arguments(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, (dict, list, int, float, bool)) or value is None:
        return json_dumps_compact(value)
    return "{}"


def normalize_tool_call_item(value: Any, index: int = 0) -> Dict[str, Any] | None:
    if not isinstance(value, dict):
        return None

    function = value.get("function")
    if not isinstance(function, dict):
        return None

    name = function.get("name")
    if not isinstance(name, str) or not name.strip():
        return None

    call_id = value.get("id")
    if not isinstance(call_id, str) or not call_id.strip():
        call_id = f"call_{uuid.uuid4().hex[:24]}_{index}"

    return {
        "id": call_id.strip(),
        "type": "function",
        "function": {
            "name": name.strip(),
            "arguments": normalize_tool_arguments(function.get("arguments", {})),
        },
    }


def chat_content_from_upstream(protocol: str, payload: Dict[str, Any]) -> str:
    choices = payload.get("choices")
    if isinstance(choices, list) and choices:
        first = choices[0]
        if isinstance(first, dict):
            message = first.get("message")
            if isinstance(message, dict):
                content = message.get("content")
                if isinstance(content, str):
                    return content
                if content is None:
                    return ""

    if protocol == "ollama":
        message = payload.get("message")
        if isinstance(message, dict):
            content = message.get("content")
            if isinstance(content, str):
                return content
        return ""

    if protocol == "openai":
        return ""

    return ""


def chat_tool_calls_from_upstream(payload: Dict[str, Any]) -> list[Dict[str, Any]] | None:
    tool_calls_raw: Any = None

    choices = payload.get("choices")
    if isinstance(choices, list) and choices:
        first = choices[0]
        if isinstance(first, dict):
            message = first.get("message")
            if isinstance(message, dict):
                tool_calls_raw = message.get("tool_calls")

    if not isinstance(tool_calls_raw, list):
        message = payload.get("message")
        if isinstance(message, dict):
            tool_calls_raw = message.get("tool_calls")

    if not isinstance(tool_calls_raw, list) or not tool_calls_raw:
        return None

    normalized: list[Dict[str, Any]] = []
    for idx, item in enumerate(tool_calls_raw):
        tool_call = normalize_tool_call_item(item, idx)
        if tool_call is not None:
            normalized.append(tool_call)
    return normalized if normalized else None


PSEUDO_FUNCTION_BLOCK_RE = re.compile(
    r"<function=([A-Za-z0-9_.:-]+)>(.*?)</function>", re.IGNORECASE | re.DOTALL
)
PSEUDO_PARAMETER_RE = re.compile(
    r"<parameter=([A-Za-z0-9_.:-]+)>\s*(.*?)\s*</parameter>", re.IGNORECASE | re.DOTALL
)
PROMISED_ACTION_RE = re.compile(r"\b(i(?:'|’)ll|i will|let me)\b", re.IGNORECASE)
LIST_FILES_INTENT_RE = re.compile(
    r"\b(list|show|display|what(?:'s| is))\b.*\b(file|files|folder|folders|directory|workspace)\b",
    re.IGNORECASE,
)


def pseudo_tool_calls_from_content(content: str) -> tuple[str, list[Dict[str, Any]] | None]:
    if not isinstance(content, str) or not content:
        return "", None
    if "<function=" not in content or "<parameter=" not in content:
        return content, None

    normalized: list[Dict[str, Any]] = []
    for idx, match in enumerate(PSEUDO_FUNCTION_BLOCK_RE.finditer(content)):
        name = match.group(1).strip()
        body = match.group(2)
        if not name:
            continue

        arguments_obj: Dict[str, str] = {}
        for param in PSEUDO_PARAMETER_RE.finditer(body):
            param_name = param.group(1).strip()
            param_value = param.group(2).strip()
            if not param_name:
                continue
            arguments_obj[param_name] = param_value

        normalized.append(
            {
                "id": f"call_{uuid.uuid4().hex[:24]}",
                "type": "function",
                "function": {
                    "name": name,
                    "arguments": json.dumps(arguments_obj, ensure_ascii=True),
                },
            }
        )

    if not normalized:
        return content, None

    cleaned = PSEUDO_FUNCTION_BLOCK_RE.sub("", content)
    cleaned = re.sub(r"</?tool_call>", "", cleaned, flags=re.IGNORECASE)
    cleaned = cleaned.strip()
    return cleaned, normalized


def should_retry_with_required_tool_choice(
    *,
    content: str,
    tools: Any,
    tool_choice: Any,
    is_external_provider: bool,
) -> bool:
    if is_external_provider:
        return False
    if not isinstance(tools, list) or not tools:
        return False
    if tool_choice is not None:
        return False
    if not isinstance(content, str):
        return True
    stripped = content.strip()
    if not stripped:
        return True
    return bool(PROMISED_ACTION_RE.search(stripped))


def latest_user_text(messages: Any) -> str:
    if not isinstance(messages, list):
        return ""

    for item in reversed(messages):
        if not isinstance(item, dict):
            continue
        if str(item.get("role", "")).strip().lower() != "user":
            continue

        content = item.get("content")
        if isinstance(content, str):
            return content.strip()
        if isinstance(content, list):
            chunks: list[str] = []
            for block in content:
                if isinstance(block, str):
                    chunks.append(block)
                elif isinstance(block, dict):
                    text = block.get("text")
                    if isinstance(text, str):
                        chunks.append(text)
            merged = "\n".join(part for part in chunks if part)
            if merged.strip():
                return merged.strip()
    return ""


def extract_function_tool_name(tools: Any, preferred: str) -> str | None:
    if not isinstance(tools, list):
        return None

    preferred_lower = preferred.strip().lower()
    fallback_name: str | None = None
    for item in tools:
        if not isinstance(item, dict):
            continue
        function = item.get("function")
        if not isinstance(function, dict):
            continue
        name = function.get("name")
        if not isinstance(name, str) or not name.strip():
            continue
        if fallback_name is None:
            fallback_name = name.strip()
        if name.strip().lower() == preferred_lower:
            return name.strip()
    return fallback_name


def synthetic_tool_call_for_empty_response(messages: Any, tools: Any, content: str) -> list[Dict[str, Any]] | None:
    if not isinstance(content, str):
        return None

    user_text = latest_user_text(messages)
    if not user_text:
        return None

    if not LIST_FILES_INTENT_RE.search(user_text):
        return None

    stripped_content = content.strip()
    if stripped_content and not PROMISED_ACTION_RE.search(stripped_content):
        return None

    tool_name = extract_function_tool_name(tools, "Bash")
    if tool_name is None:
        return None

    arguments = {"command": "ls -la", "description": "List files in current workspace directory"}
    return [
        {
            "id": f"call_{uuid.uuid4().hex[:24]}",
            "type": "function",
            "function": {
                "name": tool_name,
                "arguments": json.dumps(arguments, ensure_ascii=True),
            },
        }
    ]


def chat_finish_reason_from_upstream(payload: Dict[str, Any], has_tool_calls: bool) -> str:
    candidate: Any = None
    choices = payload.get("choices")
    if isinstance(choices, list) and choices:
        first = choices[0]
        if isinstance(first, dict):
            candidate = first.get("finish_reason")

    if not isinstance(candidate, str) or not candidate.strip():
        candidate = payload.get("done_reason")

    normalized = str(candidate).strip().lower() if isinstance(candidate, str) else ""
    if normalized in ("tool_call", "tool_calls"):
        return "tool_calls"
    if normalized in ("length", "max_tokens"):
        return "length"
    if normalized in ("content_filter",):
        return "content_filter"
    if normalized in ("stop", "end_turn"):
        return "stop"
    if has_tool_calls:
        return "tool_calls"
    return "stop"


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


async def handle_chat_completion_endpoint(
    request: Request,
    *,
    endpoint: str,
    payload: Dict[str, Any],
    messages: Any,
    requested_model: str | None,
    session: str,
    tools: Any = None,
    tool_choice: Any = None,
    response_builder: Callable[
        [str, str, Dict[str, int] | None, list[Dict[str, Any]] | None, str], Dict[str, Any]
    ],
    stream: bool = False,
    stream_builder: Callable[
        [str, str, Dict[str, int] | None, list[Dict[str, Any]] | None, str], str
    ] | None = None,
) -> Response:
    project = request.headers.get("X-Agent-Project", "-")
    allow_switch = header_bool(request.headers.get("X-Model-Switch"))
    llm_mode = state.get_llm_mode()
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
                endpoint=endpoint,
                decision="denied",
                model_requested=requested_model,
                model_served=None,
                status_code=429,
                latency_ms=latency_ms,
                backend=state.default_backend,
                provider=backend_provider_name(state.default_backend),
                reason="queue_timeout",
                llm_mode=llm_mode,
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
    is_external_provider = False
    external_tokens_used = 0
    usage: Dict[str, int] | None = None
    quota_detail: Dict[str, Any] = {}
    response_tool_calls: list[Dict[str, Any]] | None = None
    finish_reason = "stop"
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
        is_external_provider = provider_is_external(provider)
        llm_mode = state.get_llm_mode()

        if llm_mode == "local" and is_external_provider:
            status_code = 403
            reason = "external_provider_disabled"
            return llm_mode_block_response(provider, endpoint, llm_mode)

        use_dry_run = state.enable_test_mode and header_bool(request.headers.get("X-Gate-Dry-Run"))
        if is_external_provider:
            estimated_tokens = extract_test_tokens(request) if use_dry_run else 0
            allowed, quota_detail = await state.external_quota_precheck(provider, project, estimated_tokens)
            if not allowed:
                status_code = 429
                reason = "external_quota_exceeded"
                return quota_exceeded_response(provider, quota_detail)

        if use_dry_run:
            sleep_seconds = extract_test_sleep_seconds(request)
            if sleep_seconds > 0:
                await asyncio.sleep(sleep_seconds)
            content = f"gate dry-run response for session={session} model={model_served} backend={backend}"
            if is_external_provider:
                external_tokens_used = extract_test_tokens(request)
                if external_tokens_used > 0:
                    usage = {
                        "input_tokens": external_tokens_used,
                        "output_tokens": 0,
                        "total_tokens": external_tokens_used,
                    }
        else:
            try:
                upstream_status, upstream_json, upstream_text = await backend_chat_completion(
                    backend,
                    model_served,
                    messages,
                    tools=tools,
                    tool_choice=tool_choice,
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
            effective_upstream_json = upstream_json
            content = chat_content_from_upstream(protocol, upstream_json)
            response_tool_calls = chat_tool_calls_from_upstream(upstream_json)
            if response_tool_calls is None:
                content, response_tool_calls = pseudo_tool_calls_from_content(content)

            if response_tool_calls is None and should_retry_with_required_tool_choice(
                content=content,
                tools=tools,
                tool_choice=tool_choice,
                is_external_provider=is_external_provider,
            ):
                retry_status, retry_json, _retry_text = await backend_chat_completion(
                    backend,
                    model_served,
                    messages,
                    tools=tools,
                    tool_choice="required",
                )
                if retry_status == 200:
                    retry_content = chat_content_from_upstream(protocol, retry_json)
                    retry_tool_calls = chat_tool_calls_from_upstream(retry_json)
                    if retry_tool_calls is None:
                        retry_content, retry_tool_calls = pseudo_tool_calls_from_content(retry_content)
                    if retry_tool_calls is not None:
                        effective_upstream_json = retry_json
                        content = retry_content
                        response_tool_calls = retry_tool_calls

            if response_tool_calls is None:
                response_tool_calls = synthetic_tool_call_for_empty_response(messages, tools, content)

            finish_reason = chat_finish_reason_from_upstream(
                effective_upstream_json, response_tool_calls is not None
            )
            usage = extract_usage_from_upstream(protocol, effective_upstream_json)
            if is_external_provider:
                external_tokens_used = (
                    usage["total_tokens"] if usage is not None else extract_total_tokens(effective_upstream_json)
                )

        if is_external_provider:
            await state.external_quota_record(provider, project, external_tokens_used)

        effective_model = model_served or requested_model or "unknown"
        if stream and stream_builder is not None:
            headers = gate_response_headers(
                decision=decision,
                backend=backend,
                provider=provider,
                llm_mode=llm_mode,
                model_served=effective_model,
            )
            headers["Content-Type"] = "text/event-stream; charset=utf-8"
            return Response(
                status_code=200,
                content=stream_builder(effective_model, content, usage, response_tool_calls, finish_reason),
                headers=headers,
            )

        response_payload = response_builder(effective_model, content, usage, response_tool_calls, finish_reason)
        return JSONResponse(
            status_code=200,
            content=response_payload,
            headers=gate_response_headers(
                decision=decision,
                backend=backend,
                provider=provider,
                llm_mode=llm_mode,
                model_served=effective_model,
            ),
        )
    finally:
        await release_gate_slot(acquired)
        await state.mark_decision("denied" if status_code == 429 else decision)
        latency_ms = int((time.monotonic() - started) * 1000)
        state.write_log(
            event_base(
                session=session,
                project=project,
                endpoint=endpoint,
                decision="denied" if status_code == 429 else decision,
                model_requested=requested_model,
                model_served=model_served,
                status_code=status_code,
                latency_ms=latency_ms,
                backend=backend,
                provider=provider,
                model_switch=model_switch,
                reason=reason,
                llm_mode=llm_mode,
                external_tokens=external_tokens_used if is_external_provider else None,
            )
        )


def extract_text_content(value: Any) -> str:
    if isinstance(value, str):
        return value

    if isinstance(value, dict):
        for key in ("text", "input_text", "content", "value"):
            candidate = value.get(key)
            if isinstance(candidate, str):
                return candidate
            if isinstance(candidate, (dict, list)):
                nested = extract_text_content(candidate)
                if nested:
                    return nested
        return ""

    if isinstance(value, list):
        parts: list[str] = []
        for item in value:
            text = extract_text_content(item)
            if text:
                parts.append(text)
        return "\n".join(parts)

    return ""


def normalize_chat_role(value: Any) -> str:
    if not isinstance(value, str):
        return "user"

    role = value.strip().lower()
    if role in ("system", "developer"):
        return "system"
    if role == "assistant":
        return "assistant"
    if role == "tool":
        return "tool"
    return "user"


def normalize_session_name(value: Any, fallback: str) -> str:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return fallback


def normalize_tools_payload(value: Any) -> list[Dict[str, Any]] | None:
    if not isinstance(value, list) or not value:
        return None

    normalized: list[Dict[str, Any]] = []
    for item in value:
        if not isinstance(item, dict):
            continue

        item_type = item.get("type")
        function = item.get("function")
        if item_type == "function" and isinstance(function, dict):
            name = function.get("name")
            if not isinstance(name, str) or not name.strip():
                continue
            normalized_function: Dict[str, Any] = {"name": name.strip()}
            description = function.get("description")
            if isinstance(description, str) and description.strip():
                normalized_function["description"] = description.strip()
            parameters = function.get("parameters")
            if isinstance(parameters, dict):
                normalized_function["parameters"] = parameters
            normalized.append({"type": "function", "function": normalized_function})
            continue

        # Anthropic /messages tool schema -> OpenAI tools schema.
        name = item.get("name")
        if not isinstance(name, str) or not name.strip():
            continue
        normalized_function = {"name": name.strip()}
        description = item.get("description")
        if isinstance(description, str) and description.strip():
            normalized_function["description"] = description.strip()
        input_schema = item.get("input_schema")
        if isinstance(input_schema, dict):
            normalized_function["parameters"] = input_schema
        normalized.append({"type": "function", "function": normalized_function})

    return normalized if normalized else None


def normalize_tool_choice_payload(value: Any) -> str | Dict[str, Any] | None:
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in ("none", "auto", "required"):
            return lowered
        if lowered == "any":
            return "required"
        return None

    if not isinstance(value, dict):
        return None

    choice_type = value.get("type")
    if isinstance(choice_type, str):
        choice_type = choice_type.strip().lower()
        if choice_type in ("none", "auto"):
            return choice_type
        if choice_type in ("any", "required"):
            return "required"
        if choice_type == "tool":
            name = value.get("name")
            if isinstance(name, str) and name.strip():
                return {"type": "function", "function": {"name": name.strip()}}
        if choice_type == "function":
            function = value.get("function")
            if isinstance(function, dict):
                name = function.get("name")
                if isinstance(name, str) and name.strip():
                    return {"type": "function", "function": {"name": name.strip()}}

    function = value.get("function")
    if isinstance(function, dict):
        name = function.get("name")
        if isinstance(name, str) and name.strip():
            return {"type": "function", "function": {"name": name.strip()}}

    return None


def responses_tool_call_from_item(item: Dict[str, Any], index: int = 0) -> Dict[str, Any] | None:
    name = item.get("name")
    if not isinstance(name, str) or not name.strip():
        return None
    call_id = item.get("call_id")
    if not isinstance(call_id, str) or not call_id.strip():
        item_id = item.get("id")
        if isinstance(item_id, str) and item_id.strip():
            call_id = item_id.strip()
        else:
            call_id = f"call_{uuid.uuid4().hex[:24]}_{index}"
    return {
        "id": call_id,
        "type": "function",
        "function": {
            "name": name.strip(),
            "arguments": normalize_tool_arguments(item.get("arguments", {})),
        },
    }


def messages_from_responses_payload(payload: Dict[str, Any]) -> list[Dict[str, Any]]:
    messages: list[Dict[str, Any]] = []

    instructions = payload.get("instructions")
    if isinstance(instructions, str) and instructions.strip():
        messages.append({"role": "system", "content": instructions})

    input_value = payload.get("input")
    if isinstance(input_value, str):
        if input_value.strip():
            messages.append({"role": "user", "content": input_value})
        return messages

    if isinstance(input_value, dict):
        input_value = [input_value]

    if isinstance(input_value, list):
        for idx, item in enumerate(input_value):
            if isinstance(item, str):
                if item.strip():
                    messages.append({"role": "user", "content": item})
                continue
            if not isinstance(item, dict):
                continue

            item_type = item.get("type")
            if item_type == "function_call_output":
                call_id = item.get("call_id")
                if not isinstance(call_id, str) or not call_id.strip():
                    continue
                output_text = extract_text_content(item.get("output"))
                if not output_text:
                    output_text = extract_text_content(item.get("content"))
                messages.append({"role": "tool", "tool_call_id": call_id.strip(), "content": output_text})
                continue

            if item_type == "function_call":
                tool_call = responses_tool_call_from_item(item, idx)
                if tool_call is not None:
                    messages.append({"role": "assistant", "content": "", "tool_calls": [tool_call]})
                continue

            if item_type == "message":
                role = normalize_chat_role(item.get("role"))
                content_value = item.get("content")
                text = extract_text_content(content_value)
                nested_tool_calls: list[Dict[str, Any]] = []
                if isinstance(content_value, list):
                    for nested_idx, block in enumerate(content_value):
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") != "function_call":
                            continue
                        tool_call = responses_tool_call_from_item(block, nested_idx)
                        if tool_call is not None:
                            nested_tool_calls.append(tool_call)
                if nested_tool_calls:
                    messages.append({"role": "assistant", "content": text if text else "", "tool_calls": nested_tool_calls})
                elif role == "tool":
                    call_id = item.get("tool_call_id")
                    if not isinstance(call_id, str) or not call_id.strip():
                        call_id = item.get("call_id")
                    if isinstance(call_id, str) and call_id.strip():
                        messages.append({"role": "tool", "tool_call_id": call_id.strip(), "content": text})
                elif text:
                    messages.append({"role": role, "content": text})
                continue

            role = normalize_chat_role(item.get("role"))
            text = extract_text_content(item.get("content"))
            if not text:
                text = extract_text_content(item)
            if role == "tool":
                call_id = item.get("tool_call_id")
                if not isinstance(call_id, str) or not call_id.strip():
                    call_id = item.get("call_id")
                if isinstance(call_id, str) and call_id.strip():
                    messages.append({"role": "tool", "tool_call_id": call_id.strip(), "content": text})
                    continue
            if text:
                messages.append({"role": role, "content": text})
        return messages

    return messages


def messages_from_anthropic_payload(payload: Dict[str, Any]) -> list[Dict[str, Any]]:
    messages: list[Dict[str, Any]] = []

    system_text = extract_text_content(payload.get("system"))
    if system_text:
        messages.append({"role": "system", "content": system_text})

    raw_messages = payload.get("messages")
    if not isinstance(raw_messages, list):
        return messages

    for item in raw_messages:
        if not isinstance(item, dict):
            continue
        role = normalize_chat_role(item.get("role"))
        if role == "system":
            role = "user"
        content_value = item.get("content")
        text = extract_text_content(content_value)
        if isinstance(content_value, list) and role == "assistant":
            tool_calls: list[Dict[str, Any]] = []
            for idx, block in enumerate(content_value):
                if not isinstance(block, dict):
                    continue
                if block.get("type") != "tool_use":
                    continue
                name = block.get("name")
                if not isinstance(name, str) or not name.strip():
                    continue
                call_id = block.get("id")
                if not isinstance(call_id, str) or not call_id.strip():
                    call_id = f"toolu_{uuid.uuid4().hex[:24]}_{idx}"
                tool_calls.append(
                    {
                        "id": call_id.strip(),
                        "type": "function",
                        "function": {
                            "name": name.strip(),
                            "arguments": normalize_tool_arguments(block.get("input", {})),
                        },
                    }
                )
            if tool_calls:
                messages.append({"role": "assistant", "content": text if text else "", "tool_calls": tool_calls})
                continue

        if isinstance(content_value, list) and role == "user":
            user_text_parts: list[str] = []
            for block in content_value:
                if not isinstance(block, dict):
                    block_text = extract_text_content(block)
                    if block_text:
                        user_text_parts.append(block_text)
                    continue
                if block.get("type") != "tool_result":
                    block_text = extract_text_content(block)
                    if block_text:
                        user_text_parts.append(block_text)
                    continue
                tool_call_id = block.get("tool_use_id")
                if not isinstance(tool_call_id, str) or not tool_call_id.strip():
                    continue
                tool_content = extract_text_content(block.get("content"))
                messages.append({"role": "tool", "tool_call_id": tool_call_id.strip(), "content": tool_content})
            if user_text_parts:
                messages.append({"role": "user", "content": "\n".join(user_text_parts)})
            continue

        if text:
            messages.append({"role": role, "content": text})
    return messages


def sse_event(event: str, payload: Dict[str, Any]) -> str:
    return f"event: {event}\ndata: {json.dumps(payload, separators=(',', ':'))}\n\n"


def chat_completion_usage_from_normalized(usage: Dict[str, int] | None) -> Dict[str, int] | None:
    if usage is None:
        return None
    return {
        "prompt_tokens": usage["input_tokens"],
        "completion_tokens": usage["output_tokens"],
        "total_tokens": usage["total_tokens"],
    }


def responses_usage_from_normalized(usage: Dict[str, int] | None) -> Dict[str, int] | None:
    if usage is None:
        return None
    return {
        "input_tokens": usage["input_tokens"],
        "output_tokens": usage["output_tokens"],
        "total_tokens": usage["total_tokens"],
    }


def anthropic_usage_from_normalized(usage: Dict[str, int] | None) -> Dict[str, int] | None:
    if usage is None:
        return None
    return {"input_tokens": usage["input_tokens"], "output_tokens": usage["output_tokens"]}


def build_chat_completion_payload(
    model: str,
    content: str,
    usage: Dict[str, int] | None = None,
    tool_calls: list[Dict[str, Any]] | None = None,
    finish_reason: str = "stop",
) -> Dict[str, Any]:
    message: Dict[str, Any] = {"role": "assistant"}
    if tool_calls:
        message["tool_calls"] = tool_calls
        message["content"] = content if content else None
    else:
        message["content"] = content

    payload = {
        "id": f"chatcmpl-{uuid.uuid4().hex}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": message,
                "finish_reason": finish_reason,
            }
        ],
    }
    usage_payload = chat_completion_usage_from_normalized(usage)
    if usage_payload is not None:
        payload["usage"] = usage_payload
    return payload


def build_chat_completion_stream(
    model: str,
    content: str,
    usage: Dict[str, int] | None = None,
    tool_calls: list[Dict[str, Any]] | None = None,
    finish_reason: str = "stop",
) -> str:
    stream_id = f"chatcmpl-{uuid.uuid4().hex}"
    created = int(time.time())
    events: list[str] = []

    def append_chunk(choice_delta: Dict[str, Any], chunk_finish_reason: str | None = None) -> None:
        payload: Dict[str, Any] = {
            "id": stream_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "delta": choice_delta,
                    "finish_reason": chunk_finish_reason,
                }
            ],
        }
        events.append(f"data: {json.dumps(payload, separators=(',', ':'))}\n\n")

    # Start with assistant role marker to stay compatible with OpenAI-style chat streaming clients.
    append_chunk({"role": "assistant"})

    if tool_calls:
        tool_call_deltas: list[Dict[str, Any]] = []
        for index, tool_call in enumerate(tool_calls):
            if not isinstance(tool_call, dict):
                continue
            function = tool_call.get("function")
            if not isinstance(function, dict):
                continue
            name = function.get("name")
            if not isinstance(name, str) or not name.strip():
                continue
            raw_arguments = function.get("arguments")
            arguments = raw_arguments if isinstance(raw_arguments, str) else normalize_tool_arguments(raw_arguments)
            tool_call_id = tool_call.get("id")
            if not isinstance(tool_call_id, str) or not tool_call_id.strip():
                tool_call_id = f"call_{uuid.uuid4().hex[:24]}"
            tool_call_deltas.append(
                {
                    "index": index,
                    "id": tool_call_id.strip(),
                    "type": "function",
                    "function": {
                        "name": name.strip(),
                        "arguments": arguments,
                    },
                }
            )
        if tool_call_deltas:
            append_chunk({"tool_calls": tool_call_deltas})
    elif isinstance(content, str) and content:
        append_chunk({"content": content})

    final_payload: Dict[str, Any] = {
        "id": stream_id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": model,
        "choices": [
            {
                "index": 0,
                "delta": {},
                "finish_reason": finish_reason,
            }
        ],
    }
    usage_payload = chat_completion_usage_from_normalized(usage)
    if usage_payload is not None:
        final_payload["usage"] = usage_payload
    events.append(f"data: {json.dumps(final_payload, separators=(',', ':'))}\n\n")
    events.append("data: [DONE]\n\n")
    return "".join(events)


def parse_tool_arguments_json(arguments_raw: str) -> Any:
    try:
        return json.loads(arguments_raw)
    except Exception:
        return {}


def build_responses_payload(
    model: str,
    content: str,
    usage: Dict[str, int] | None = None,
    tool_calls: list[Dict[str, Any]] | None = None,
    finish_reason: str = "stop",
) -> Dict[str, Any]:
    response_id = f"resp_{uuid.uuid4().hex}"
    message_id = f"msg_{uuid.uuid4().hex}"
    output: list[Dict[str, Any]] = []

    if content:
        output.append(
            {
                "id": message_id,
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [{"type": "output_text", "text": content, "annotations": []}],
            }
        )

    if tool_calls:
        for tool_call in tool_calls:
            fn = tool_call.get("function") if isinstance(tool_call, dict) else None
            name = fn.get("name") if isinstance(fn, dict) else None
            arguments = fn.get("arguments") if isinstance(fn, dict) else None
            call_id = tool_call.get("id") if isinstance(tool_call, dict) else None
            if not isinstance(name, str) or not name.strip():
                continue
            if not isinstance(call_id, str) or not call_id.strip():
                call_id = f"call_{uuid.uuid4().hex[:24]}"
            output.append(
                {
                    "id": f"fc_{uuid.uuid4().hex}",
                    "type": "function_call",
                    "status": "completed",
                    "name": name.strip(),
                    "arguments": normalize_tool_arguments(arguments),
                    "call_id": call_id.strip(),
                }
            )

    if not output:
        output.append(
            {
                "id": message_id,
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [{"type": "output_text", "text": content, "annotations": []}],
            }
        )

    payload = {
        "id": response_id,
        "object": "response",
        "created_at": now_iso(),
        "status": "completed",
        "model": model,
        "output_text": content,
        "error": None,
        "output": output,
    }
    if finish_reason:
        payload["finish_reason"] = finish_reason
    usage_payload = responses_usage_from_normalized(usage)
    if usage_payload is not None:
        payload["usage"] = usage_payload
    return payload


def build_responses_stream(
    model: str,
    content: str,
    usage: Dict[str, int] | None = None,
    tool_calls: list[Dict[str, Any]] | None = None,
    finish_reason: str = "stop",
) -> str:
    final_payload = build_responses_payload(model, content, usage, tool_calls, finish_reason)
    response_id = final_payload["id"]
    output = final_payload.get("output")
    if not isinstance(output, list) or not output:
        output = [
            {
                "id": f"msg_{uuid.uuid4().hex}",
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [{"type": "output_text", "text": content, "annotations": []}],
            }
        ]
    created_payload = {
        "type": "response.created",
        "response": {
            "id": response_id,
            "object": "response",
            "created_at": final_payload["created_at"],
            "status": "in_progress",
            "model": model,
            "output": [],
        },
    }
    in_progress_payload = {
        "type": "response.in_progress",
        "response": {
            "id": response_id,
            "object": "response",
            "created_at": final_payload["created_at"],
            "status": "in_progress",
            "model": model,
            "output": [],
        },
    }
    completed_payload = {"type": "response.completed", "response": final_payload}
    events: list[str] = [
        sse_event("response.created", created_payload),
        sse_event("response.in_progress", in_progress_payload),
    ]

    for output_index, output_item in enumerate(output):
        if not isinstance(output_item, dict):
            continue
        item_type = output_item.get("type")
        output_item_id = output_item.get("id")
        if not isinstance(output_item_id, str) or not output_item_id.strip():
            output_item_id = f"item_{uuid.uuid4().hex}"
        output_item_id = output_item_id.strip()

        if item_type == "function_call":
            name = output_item.get("name")
            if not isinstance(name, str) or not name.strip():
                name = "function"
            call_id = output_item.get("call_id")
            if not isinstance(call_id, str) or not call_id.strip():
                call_id = f"call_{uuid.uuid4().hex[:24]}"
            arguments = normalize_tool_arguments(output_item.get("arguments", {}))
            in_progress_item = {
                "id": output_item_id,
                "type": "function_call",
                "status": "in_progress",
                "name": name.strip(),
                "arguments": "",
                "call_id": call_id.strip(),
            }
            events.append(
                sse_event(
                    "response.output_item.added",
                    {
                        "type": "response.output_item.added",
                        "response_id": response_id,
                        "output_index": output_index,
                        "item": in_progress_item,
                    },
                )
            )
            if arguments:
                events.append(
                    sse_event(
                        "response.function_call_arguments.delta",
                        {
                            "type": "response.function_call_arguments.delta",
                            "response_id": response_id,
                            "output_index": output_index,
                            "item_id": output_item_id,
                            "delta": arguments,
                        },
                    )
                )
            events.append(
                sse_event(
                    "response.function_call_arguments.done",
                    {
                        "type": "response.function_call_arguments.done",
                        "response_id": response_id,
                        "output_index": output_index,
                        "item_id": output_item_id,
                        "arguments": arguments,
                    },
                )
            )
            events.append(
                sse_event(
                    "response.output_item.done",
                    {
                        "type": "response.output_item.done",
                        "response_id": response_id,
                        "output_index": output_index,
                        "item": output_item,
                    },
                )
            )
            continue

        output_content = output_item.get("content")
        if not isinstance(output_content, list) or not output_content:
            output_content = [{"type": "output_text", "text": "", "annotations": []}]
        in_progress_item = dict(output_item)
        in_progress_item["status"] = "in_progress"
        in_progress_item["content"] = []
        events.append(
            sse_event(
                "response.output_item.added",
                {
                    "type": "response.output_item.added",
                    "response_id": response_id,
                    "output_index": output_index,
                    "item": in_progress_item,
                },
            )
        )
        for content_index, output_part in enumerate(output_content):
            if not isinstance(output_part, dict):
                continue
            part_type = output_part.get("type")
            if part_type != "output_text":
                continue
            part_text = output_part.get("text") if isinstance(output_part.get("text"), str) else ""
            events.append(
                sse_event(
                    "response.content_part.added",
                    {
                        "type": "response.content_part.added",
                        "response_id": response_id,
                        "output_index": output_index,
                        "item_id": output_item_id,
                        "content_index": content_index,
                        "part": {"type": "output_text", "text": ""},
                    },
                )
            )
            if part_text:
                events.append(
                    sse_event(
                        "response.output_text.delta",
                        {
                            "type": "response.output_text.delta",
                            "response_id": response_id,
                            "output_index": output_index,
                            "item_id": output_item_id,
                            "content_index": content_index,
                            "delta": part_text,
                        },
                    )
                )
            events.append(
                sse_event(
                    "response.output_text.done",
                    {
                        "type": "response.output_text.done",
                        "response_id": response_id,
                        "output_index": output_index,
                        "item_id": output_item_id,
                        "content_index": content_index,
                        "text": part_text,
                    },
                )
            )
            events.append(
                sse_event(
                    "response.content_part.done",
                    {
                        "type": "response.content_part.done",
                        "response_id": response_id,
                        "output_index": output_index,
                        "item_id": output_item_id,
                        "content_index": content_index,
                        "part": output_part,
                    },
                )
            )
        events.append(
            sse_event(
                "response.output_item.done",
                {
                    "type": "response.output_item.done",
                    "response_id": response_id,
                    "output_index": output_index,
                    "item": output_item,
                },
            )
        )

    events.append(sse_event("response.completed", completed_payload))
    events.append("data: [DONE]\n\n")
    return "".join(events)


def anthropic_stop_reason_from_finish_reason(finish_reason: str, has_tool_calls: bool) -> str:
    if has_tool_calls:
        return "tool_use"
    normalized = finish_reason.strip().lower() if isinstance(finish_reason, str) else ""
    if normalized in ("length", "max_tokens"):
        return "max_tokens"
    return "end_turn"


def build_anthropic_message_payload(
    model: str,
    content: str,
    usage: Dict[str, int] | None = None,
    tool_calls: list[Dict[str, Any]] | None = None,
    finish_reason: str = "stop",
) -> Dict[str, Any]:
    content_blocks: list[Dict[str, Any]] = []
    if content:
        content_blocks.append({"type": "text", "text": content})

    if tool_calls:
        for item in tool_calls:
            function = item.get("function") if isinstance(item, dict) else None
            name = function.get("name") if isinstance(function, dict) else None
            arguments = function.get("arguments") if isinstance(function, dict) else None
            call_id = item.get("id") if isinstance(item, dict) else None
            if not isinstance(name, str) or not name.strip():
                continue
            if not isinstance(call_id, str) or not call_id.strip():
                call_id = f"toolu_{uuid.uuid4().hex[:24]}"
            content_blocks.append(
                {
                    "type": "tool_use",
                    "id": call_id.strip(),
                    "name": name.strip(),
                    "input": parse_tool_arguments_json(normalize_tool_arguments(arguments)),
                }
            )

    if not content_blocks:
        content_blocks = [{"type": "text", "text": ""}]

    payload = {
        "id": f"msg_{uuid.uuid4().hex}",
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": content_blocks,
        "stop_reason": anthropic_stop_reason_from_finish_reason(finish_reason, bool(tool_calls)),
        "stop_sequence": None,
    }
    usage_payload = anthropic_usage_from_normalized(usage)
    if usage_payload is not None:
        payload["usage"] = usage_payload
    return payload


def build_anthropic_message_stream(
    model: str,
    content: str,
    usage: Dict[str, int] | None = None,
    tool_calls: list[Dict[str, Any]] | None = None,
    finish_reason: str = "stop",
) -> str:
    payload = build_anthropic_message_payload(model, content, usage, tool_calls, finish_reason)
    message_start = dict(payload)
    message_start["content"] = []
    message_start["stop_reason"] = None
    message_delta_payload = {
        "type": "message_delta",
        "delta": {"stop_reason": payload.get("stop_reason"), "stop_sequence": None},
    }
    usage_payload = anthropic_usage_from_normalized(usage)
    if usage_payload is not None:
        message_delta_payload["usage"] = {"output_tokens": usage_payload["output_tokens"]}
    events = [sse_event("message_start", {"type": "message_start", "message": message_start})]

    content_blocks = payload.get("content")
    if not isinstance(content_blocks, list):
        content_blocks = [{"type": "text", "text": ""}]

    for idx, block in enumerate(content_blocks):
        if not isinstance(block, dict):
            continue

        block_type = str(block.get("type", "")).strip().lower()
        if block_type == "tool_use":
            tool_id = block.get("id")
            tool_name = block.get("name")
            tool_input = block.get("input")
            if not isinstance(tool_id, str) or not tool_id.strip():
                tool_id = f"toolu_{uuid.uuid4().hex[:24]}"
            if not isinstance(tool_name, str) or not tool_name.strip():
                continue
            if not isinstance(tool_input, (dict, list)):
                tool_input = {}

            events.append(
                sse_event(
                    "content_block_start",
                    {
                        "type": "content_block_start",
                        "index": idx,
                        "content_block": {
                            "type": "tool_use",
                            "id": tool_id.strip(),
                            "name": tool_name.strip(),
                            "input": {},
                        },
                    },
                )
            )
            events.append(
                sse_event(
                    "content_block_delta",
                    {
                        "type": "content_block_delta",
                        "index": idx,
                        "delta": {
                            "type": "input_json_delta",
                            "partial_json": json.dumps(tool_input, ensure_ascii=True),
                        },
                    },
                )
            )
            events.append(sse_event("content_block_stop", {"type": "content_block_stop", "index": idx}))
            continue

        text = block.get("text")
        if not isinstance(text, str):
            text = ""
        events.append(
            sse_event(
                "content_block_start",
                {"type": "content_block_start", "index": idx, "content_block": {"type": "text", "text": ""}},
            )
        )
        if text:
            events.append(
                sse_event(
                    "content_block_delta",
                    {"type": "content_block_delta", "index": idx, "delta": {"type": "text_delta", "text": text}},
                )
            )
        events.append(sse_event("content_block_stop", {"type": "content_block_stop", "index": idx}))

    events.append(sse_event("message_delta", message_delta_payload))
    events.append(sse_event("message_stop", {"type": "message_stop"}))
    return "".join(events)


@app.post("/v1/chat/completions")
async def v1_chat_completions(request: Request) -> Response:
    payload, error = await read_json_body(request)
    if error is not None or payload is None:
        return error

    requested_model = payload.get("model") if isinstance(payload.get("model"), str) else None
    session = normalize_session_name(request.headers.get("X-Agent-Session") or payload.get("user"), "anonymous")
    messages = payload.get("messages", [])
    tools = normalize_tools_payload(payload.get("tools"))
    tool_choice = normalize_tool_choice_payload(payload.get("tool_choice"))
    stream = bool(payload.get("stream"))

    return await handle_chat_completion_endpoint(
        request,
        endpoint="/v1/chat/completions",
        payload=payload,
        messages=messages,
        requested_model=requested_model,
        session=session,
        tools=tools,
        tool_choice=tool_choice,
        response_builder=build_chat_completion_payload,
        stream=stream,
        stream_builder=build_chat_completion_stream,
    )


@app.post("/responses")
@app.post("/v1/responses")
async def v1_responses(request: Request) -> Response:
    payload, error = await read_json_body(request)
    if error is not None or payload is None:
        return error

    requested_model = payload.get("model") if isinstance(payload.get("model"), str) else None
    session = normalize_session_name(request.headers.get("X-Agent-Session") or payload.get("user"), "responses")
    messages = messages_from_responses_payload(payload)
    tools = normalize_tools_payload(payload.get("tools"))
    tool_choice = normalize_tool_choice_payload(payload.get("tool_choice"))
    if not messages:
        return JSONResponse(
            status_code=400,
            content={
                "error": {
                    "message": "input must contain at least one text message",
                    "type": "invalid_request_error",
                }
            },
        )

    stream = bool(payload.get("stream"))
    endpoint = request.url.path if request.url.path in ("/responses", "/v1/responses") else "/v1/responses"
    return await handle_chat_completion_endpoint(
        request,
        endpoint=endpoint,
        payload=payload,
        messages=messages,
        requested_model=requested_model,
        session=session,
        tools=tools,
        tool_choice=tool_choice,
        response_builder=build_responses_payload,
        stream=stream,
        stream_builder=build_responses_stream,
    )


@app.post("/messages")
@app.post("/v1/messages")
async def v1_messages(request: Request) -> Response:
    payload, error = await read_json_body(request)
    if error is not None or payload is None:
        return error

    requested_model = payload.get("model") if isinstance(payload.get("model"), str) else None
    metadata = payload.get("metadata")
    metadata_user = metadata.get("user_id") if isinstance(metadata, dict) else None
    session = normalize_session_name(request.headers.get("X-Agent-Session") or metadata_user, "messages")
    messages = messages_from_anthropic_payload(payload)
    tools = normalize_tools_payload(payload.get("tools"))
    tool_choice = normalize_tool_choice_payload(payload.get("tool_choice"))
    if not messages:
        return JSONResponse(
            status_code=400,
            content={
                "error": {
                    "message": "messages must contain at least one text item",
                    "type": "invalid_request_error",
                }
            },
        )

    stream = bool(payload.get("stream"))
    endpoint = request.url.path if request.url.path in ("/messages", "/v1/messages") else "/v1/messages"
    return await handle_chat_completion_endpoint(
        request,
        endpoint=endpoint,
        payload=payload,
        messages=messages,
        requested_model=requested_model,
        session=session,
        tools=tools,
        tool_choice=tool_choice,
        response_builder=build_anthropic_message_payload,
        stream=stream,
        stream_builder=build_anthropic_message_stream,
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
    llm_mode = state.get_llm_mode()
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
                llm_mode=llm_mode,
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
    is_external_provider = False
    external_tokens_used = 0
    embedding_prompt_tokens = 0
    embedding_total_tokens = 0
    embedding_usage_observed = False
    quota_detail: Dict[str, Any] = {}
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
        is_external_provider = provider_is_external(provider)
        llm_mode = state.get_llm_mode()

        if llm_mode == "local" and is_external_provider:
            status_code = 403
            reason = "external_provider_disabled"
            return llm_mode_block_response(provider, "/v1/embeddings", llm_mode)

        use_dry_run = state.enable_test_mode and header_bool(request.headers.get("X-Gate-Dry-Run"))
        if is_external_provider:
            estimated_tokens = extract_test_tokens(request) if use_dry_run else 0
            allowed, quota_detail = await state.external_quota_precheck(provider, project, estimated_tokens)
            if not allowed:
                status_code = 429
                reason = "external_quota_exceeded"
                return quota_exceeded_response(provider, quota_detail)

        vectors: list[list[float]] = []
        if use_dry_run:
            for item in inputs:
                vectors.append(deterministic_embedding_vector(f"{model_served}:{item}:{backend}"))
            if is_external_provider:
                external_tokens_used = extract_test_tokens(request)
                if external_tokens_used > 0:
                    embedding_prompt_tokens = external_tokens_used
                    embedding_total_tokens = external_tokens_used
                    embedding_usage_observed = True
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
                usage = extract_usage_from_upstream(protocol, upstream_json)
                if usage is not None:
                    embedding_prompt_tokens += usage["input_tokens"]
                    embedding_total_tokens += usage["total_tokens"]
                    embedding_usage_observed = True
                if is_external_provider:
                    external_tokens_used += usage["total_tokens"] if usage is not None else extract_total_tokens(upstream_json)

        if is_external_provider:
            await state.external_quota_record(provider, project, external_tokens_used)

        response_payload = {
            "object": "list",
            "data": [
                {"object": "embedding", "index": idx, "embedding": vector}
                for idx, vector in enumerate(vectors)
            ],
            "model": model_served,
        }
        if embedding_usage_observed:
            response_payload["usage"] = {
                "prompt_tokens": embedding_prompt_tokens,
                "total_tokens": embedding_total_tokens,
            }
        return JSONResponse(
            status_code=200,
            content=response_payload,
            headers={
                "X-Gate-Decision": decision,
                "X-Model-Served": model_served or "",
                "X-Gate-Backend": backend,
                "X-Gate-Provider": provider,
                "X-Gate-LLM-Mode": llm_mode,
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
                llm_mode=llm_mode,
                external_tokens=external_tokens_used if is_external_provider else None,
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


@app.get("/admin/llm-mode")
async def admin_llm_mode() -> JSONResponse:
    llm_mode = state.get_llm_mode()
    external = await state.snapshot_external_metrics()
    return JSONResponse(
        status_code=200,
        content={
            "llm_mode": llm_mode,
            "default_llm_mode": state.default_llm_mode,
            "mode_file": str(state.mode_file),
            "quotas_file": str(state.quotas_file),
            "external": external,
        },
    )


@app.put("/admin/llm-mode")
async def admin_set_llm_mode(request: Request) -> JSONResponse:
    payload = await request.json()
    mode = payload.get("mode")
    if not isinstance(mode, str) or mode.strip().lower() not in ALLOWED_LLM_MODES:
        return JSONResponse(
            status_code=400,
            content={"error": {"message": "mode must be one of: local, hybrid, remote", "type": "invalid_mode"}},
        )

    updated_mode = state.persist_llm_mode(mode, request.headers.get("X-Agent-Actor", "api"))
    state.write_log(
        event_base(
            session="admin",
            project=request.headers.get("X-Agent-Project", "-"),
            endpoint="/admin/llm-mode",
            decision="admin_mode_set",
            model_requested=None,
            model_served=None,
            status_code=200,
            latency_ms=0,
            reason="admin_mode_set",
            llm_mode=updated_mode,
        )
    )
    return JSONResponse(status_code=200, content={"ok": True, "llm_mode": updated_mode})


@app.get("/admin/quotas")
async def admin_quotas() -> JSONResponse:
    external = await state.snapshot_external_metrics()
    return JSONResponse(
        status_code=200,
        content={"providers": external, "limits": state.provider_quota_limits},
    )
