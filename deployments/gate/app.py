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


def extract_total_tokens(payload: Dict[str, Any]) -> int:
    usage = payload.get("usage")
    if not isinstance(usage, dict):
        return 0
    value = usage.get("total_tokens")
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return 0
    return max(0, parsed)


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
                endpoint="/v1/chat/completions",
                decision="denied",
                model_requested=requested_model if isinstance(requested_model, str) else None,
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
    quota_detail: Dict[str, Any] = {}
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
            return llm_mode_block_response(provider, "/v1/chat/completions", llm_mode)

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
            if is_external_provider:
                external_tokens_used = extract_total_tokens(upstream_json)

        if is_external_provider:
            await state.external_quota_record(provider, project, external_tokens_used)

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
                llm_mode=llm_mode,
                external_tokens=external_tokens_used if is_external_provider else None,
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
                if is_external_provider:
                    external_tokens_used += extract_total_tokens(upstream_json)

        if is_external_provider:
            await state.external_quota_record(provider, project, external_tokens_used)

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
