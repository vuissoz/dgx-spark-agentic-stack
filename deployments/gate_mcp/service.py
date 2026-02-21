#!/usr/bin/env python3
from __future__ import annotations

import hmac
import json
import os
import re
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib import error, parse, request


def now_ts() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_positive_int(raw: str | None, default: int) -> int:
    try:
        parsed = int(str(raw))
    except (TypeError, ValueError):
        return default
    return parsed if parsed >= 0 else default


def parse_positive_float(raw: str | None, default: float) -> float:
    try:
        parsed = float(str(raw))
    except (TypeError, ValueError):
        return default
    return parsed if parsed > 0 else default


def read_token(path: str) -> str:
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def append_audit(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, separators=(",", ":")) + "\n")


class GateClientError(RuntimeError):
    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.details = details or {}


class TokenBucketLimiter:
    def __init__(self, rate_per_second: float, burst: int) -> None:
        self.rate_per_second = max(0.1, rate_per_second)
        self.burst = max(1, burst)
        self.buckets: dict[str, tuple[float, float]] = {}

    def allow(self, key: str) -> tuple[bool, float]:
        now = time.monotonic()
        tokens, last_seen = self.buckets.get(key, (float(self.burst), now))
        refill = (now - last_seen) * self.rate_per_second
        tokens = min(float(self.burst), tokens + refill)
        if tokens < 1.0:
            self.buckets[key] = (tokens, now)
            retry_after = (1.0 - tokens) / self.rate_per_second
            return False, max(0.1, retry_after)

        self.buckets[key] = (tokens - 1.0, now)
        return True, 0.0


class GateClient:
    def __init__(self, base_url: str, timeout_seconds: float) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout_seconds = timeout_seconds

    def _request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        project: str = "-",
    ) -> dict[str, Any]:
        body: bytes | None = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if project:
            headers["X-Agent-Project"] = project

        req = request.Request(
            url=f"{self.base_url}{path}",
            data=body,
            headers=headers,
            method=method.upper(),
        )

        status_code = 0
        text = ""
        try:
            with request.urlopen(req, timeout=self.timeout_seconds) as resp:
                status_code = int(resp.getcode() or 0)
                text = resp.read().decode("utf-8", errors="replace")
        except error.HTTPError as exc:
            status_code = int(exc.code or 502)
            text = exc.read().decode("utf-8", errors="replace")
        except (error.URLError, TimeoutError, OSError) as exc:
            raise GateClientError(
                status_code=502,
                code="gate_unreachable",
                message=f"gate is unreachable: {exc}",
            ) from exc

        payload_json: dict[str, Any] = {}
        if text:
            try:
                loaded = json.loads(text)
                if isinstance(loaded, dict):
                    payload_json = loaded
            except json.JSONDecodeError:
                payload_json = {}

        if status_code >= 400:
            error_obj = payload_json.get("error")
            if isinstance(error_obj, dict):
                msg = str(error_obj.get("message") or error_obj.get("type") or "gate request failed")
                code = str(error_obj.get("type") or "gate_request_failed")
            else:
                msg = "gate request failed"
                code = "gate_request_failed"
            raise GateClientError(
                status_code=status_code,
                code=code,
                message=msg,
                details=payload_json,
            )

        return payload_json

    def get(self, path: str, project: str = "-") -> dict[str, Any]:
        return self._request("GET", path, project=project)

    def post(self, path: str, payload: dict[str, Any], project: str = "-") -> dict[str, Any]:
        return self._request("POST", path, payload=payload, project=project)


@dataclass
class ServiceConfig:
    token: str
    audit_log: Path
    session_pattern: re.Pattern[str]
    model_pattern: re.Pattern[str]
    rate_limiter: TokenBucketLimiter
    gate: GateClient


def sanitize_id(value: str | None) -> str:
    if not isinstance(value, str):
        return ""
    return value.strip()


def aggregate_global_remaining(providers: dict[str, Any]) -> dict[str, int]:
    fields = (
        "remaining_daily_tokens",
        "remaining_monthly_tokens",
        "remaining_daily_requests",
        "remaining_monthly_requests",
    )
    aggregated: dict[str, int] = {}
    for field in fields:
        values: list[int] = []
        for entry in providers.values():
            if not isinstance(entry, dict):
                continue
            raw = entry.get(field)
            if isinstance(raw, bool):
                continue
            if isinstance(raw, (int, float)):
                values.append(int(raw))
        limited = [item for item in values if item >= 0]
        if limited:
            aggregated[field] = sum(max(0, item) for item in limited)
        else:
            aggregated[field] = -1
    return aggregated


class GateMCPHandler(BaseHTTPRequestHandler):
    server_version = "gate-mcp/1.0"

    @property
    def cfg(self) -> ServiceConfig:
        return self.server.cfg  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def _json_response(self, status_code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        body = self.rfile.read(max(0, length)) if length > 0 else b"{}"
        try:
            loaded = json.loads(body.decode("utf-8"))
            if isinstance(loaded, dict):
                return loaded
        except (UnicodeDecodeError, json.JSONDecodeError):
            pass
        return {}

    def _bearer_token(self) -> str:
        auth = self.headers.get("Authorization", "")
        if not auth.lower().startswith("bearer "):
            return ""
        return auth.split(" ", 1)[1].strip()

    def _auth_ok(self) -> bool:
        provided = self._bearer_token()
        expected = self.cfg.token
        return bool(provided and expected and hmac.compare_digest(provided, expected))

    def _client_key(self, session_id: str = "") -> str:
        client_ip = self.client_address[0] if isinstance(self.client_address, tuple) else "-"
        if session_id:
            return f"{client_ip}:{session_id}"
        return client_ip

    def _deny_auth(self, request_id: str, tool: str) -> None:
        append_audit(
            self.cfg.audit_log,
            {
                "ts": now_ts(),
                "module": "gate-mcp",
                "action": "execute_tool",
                "decision": "deny",
                "reason": "unauthorized",
                "request_id": request_id,
                "tool": tool,
                "client": self._client_key(),
            },
        )
        self._json_response(401, {"error": "unauthorized", "request_id": request_id})

    def _check_rate_limit(self, request_id: str, tool: str, session_id: str = "") -> bool:
        allowed, retry_after = self.cfg.rate_limiter.allow(self._client_key(session_id))
        if allowed:
            return True

        append_audit(
            self.cfg.audit_log,
            {
                "ts": now_ts(),
                "module": "gate-mcp",
                "action": "execute_tool",
                "decision": "deny",
                "reason": "rate_limited",
                "request_id": request_id,
                "tool": tool,
                "retry_after_seconds": round(retry_after, 3),
                "client": self._client_key(session_id),
            },
        )
        self._json_response(
            429,
            {
                "error": "rate_limited",
                "request_id": request_id,
                "retry_after_seconds": round(retry_after, 3),
            },
        )
        return False

    def _tool_list(self) -> list[dict[str, Any]]:
        return [
            {
                "name": "gate.current_model",
                "description": "Return current served model/backend/provider for a session.",
                "input_schema": {
                    "type": "object",
                    "properties": {"session_id": {"type": "string"}, "project": {"type": "string"}},
                    "required": ["session_id"],
                },
            },
            {
                "name": "gate.quota_remaining",
                "description": "Return remaining external quotas globally and by provider.",
                "input_schema": {"type": "object", "properties": {"project": {"type": "string"}}},
            },
            {
                "name": "gate.switch_model",
                "description": "Switch sticky model for an existing session.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "session_id": {"type": "string"},
                        "model": {"type": "string"},
                        "project": {"type": "string"},
                    },
                    "required": ["session_id", "model"],
                },
            },
        ]

    def _session_id(self, args: dict[str, Any]) -> str:
        raw = args.get("session_id")
        if not isinstance(raw, str) or not raw.strip():
            raw = self.headers.get("X-Agent-Session", "")
        session_id = sanitize_id(raw)
        if not session_id or not self.cfg.session_pattern.match(session_id):
            raise ValueError("invalid_session_id")
        return session_id

    def _project(self, args: dict[str, Any]) -> str:
        raw = args.get("project")
        if not isinstance(raw, str) or not raw.strip():
            raw = self.headers.get("X-Agent-Project", "-")
        project = sanitize_id(raw)
        return project if project else "-"

    def _validate_model(self, model: str) -> None:
        if not self.cfg.model_pattern.match(model):
            raise ValueError("invalid_model")

    def _tool_current_model(self, args: dict[str, Any]) -> dict[str, Any]:
        session_id = self._session_id(args)
        project = self._project(args)
        encoded_session = parse.quote(session_id, safe="")
        session_payload = self.cfg.gate.get(f"/admin/sessions/{encoded_session}", project=project)
        mode_payload = self.cfg.gate.get("/admin/llm-mode", project=project)
        return {
            "session_id": session_id,
            "project": project,
            "model_served": session_payload.get("model"),
            "backend": session_payload.get("backend"),
            "provider": session_payload.get("provider"),
            "llm_mode": mode_payload.get("llm_mode"),
        }

    def _tool_quota_remaining(self, args: dict[str, Any]) -> dict[str, Any]:
        project = self._project(args)
        quotas_payload = self.cfg.gate.get("/admin/quotas", project=project)
        providers_raw = quotas_payload.get("providers")
        providers: dict[str, Any] = providers_raw if isinstance(providers_raw, dict) else {}
        return {
            "project": project,
            "providers": providers,
            "global": aggregate_global_remaining(providers),
        }

    def _tool_switch_model(self, args: dict[str, Any]) -> dict[str, Any]:
        session_id = self._session_id(args)
        project = self._project(args)
        model = sanitize_id(args.get("model") if isinstance(args.get("model"), str) else "")
        if not model:
            raise ValueError("model_required")
        self._validate_model(model)

        encoded_session = parse.quote(session_id, safe="")
        response = self.cfg.gate.post(
            f"/admin/sessions/{encoded_session}/switch",
            {"model": model},
            project=project,
        )
        return {
            "session_id": session_id,
            "project": project,
            "model_served": response.get("model"),
            "backend": response.get("backend"),
            "provider": response.get("provider"),
            "model_switch": True,
        }

    def do_GET(self) -> None:
        path = parse.urlparse(self.path).path
        if path == "/healthz":
            self._json_response(200, {"ok": True, "module": "gate-mcp"})
            return

        if path not in ("/v1/tools", "/v1/tools/list"):
            self._json_response(404, {"error": "not_found"})
            return

        request_id = str(uuid.uuid4())
        if not self._auth_ok():
            self._deny_auth(request_id, "tools.list")
            return
        if not self._check_rate_limit(request_id, "tools.list"):
            return

        append_audit(
            self.cfg.audit_log,
            {
                "ts": now_ts(),
                "module": "gate-mcp",
                "action": "list_tools",
                "decision": "allow",
                "request_id": request_id,
                "client": self._client_key(),
            },
        )
        self._json_response(200, {"request_id": request_id, "tools": self._tool_list()})

    def do_POST(self) -> None:
        path = parse.urlparse(self.path).path
        if path != "/v1/tools/execute":
            self._json_response(404, {"error": "not_found"})
            return

        payload = self._read_json()
        request_id = sanitize_id(payload.get("request_id")) if isinstance(payload.get("request_id"), str) else ""
        if not request_id:
            request_id = str(uuid.uuid4())

        tool = sanitize_id(payload.get("tool")) if isinstance(payload.get("tool"), str) else ""
        if not self._auth_ok():
            self._deny_auth(request_id, tool or "-")
            return

        args_raw = payload.get("args")
        args = args_raw if isinstance(args_raw, dict) else {}
        session_for_limit = sanitize_id(args.get("session_id")) if isinstance(args.get("session_id"), str) else ""
        if not self._check_rate_limit(request_id, tool or "-", session_for_limit):
            return

        status_code = 200
        result: dict[str, Any] = {}
        decision = "allow"
        reason = "-"

        try:
            if tool == "gate.current_model":
                result = self._tool_current_model(args)
            elif tool == "gate.quota_remaining":
                result = self._tool_quota_remaining(args)
            elif tool == "gate.switch_model":
                result = self._tool_switch_model(args)
            else:
                status_code = 404
                decision = "deny"
                reason = "tool_not_found"
                result = {"error": "tool_not_found"}
        except ValueError as exc:
            status_code = 400
            decision = "deny"
            reason = str(exc)
            result = {"error": reason}
        except GateClientError as exc:
            status_code = exc.status_code
            decision = "deny"
            reason = exc.code
            result = {"error": exc.code, "message": exc.message}
            if exc.details:
                result["gate_error"] = exc.details

        audit_payload = {
            "ts": now_ts(),
            "module": "gate-mcp",
            "action": "execute_tool",
            "decision": decision,
            "reason": reason,
            "request_id": request_id,
            "tool": tool,
            "status_code": status_code,
            "client": self._client_key(session_for_limit),
        }
        session_id = result.get("session_id")
        if isinstance(session_id, str) and session_id:
            audit_payload["session_id"] = session_id
        project = result.get("project")
        if isinstance(project, str) and project:
            audit_payload["project"] = project
        model = result.get("model_served")
        if isinstance(model, str) and model:
            audit_payload["model_served"] = model
        backend = result.get("backend")
        if isinstance(backend, str) and backend:
            audit_payload["backend"] = backend
        provider = result.get("provider")
        if isinstance(provider, str) and provider:
            audit_payload["provider"] = provider
        append_audit(self.cfg.audit_log, audit_payload)

        response_payload = {"request_id": request_id, "tool": tool}
        response_payload.update(result)
        self._json_response(status_code, response_payload)


def main() -> int:
    bind_host = os.getenv("GATE_MCP_BIND_HOST", "0.0.0.0")
    bind_port = parse_positive_int(os.getenv("GATE_MCP_BIND_PORT"), 8123)
    gate_url = os.getenv("GATE_MCP_GATE_URL", "http://ollama-gate:11435")
    token_file = os.getenv("GATE_MCP_AUTH_TOKEN_FILE", "/run/secrets/gate_mcp.token")
    audit_log = Path(os.getenv("GATE_MCP_AUDIT_LOG", "/logs/audit.jsonl"))
    timeout_seconds = parse_positive_float(os.getenv("GATE_MCP_HTTP_TIMEOUT_SEC"), 5.0)
    rate_per_second = parse_positive_float(os.getenv("GATE_MCP_RATE_LIMIT_RPS"), 5.0)
    burst = parse_positive_int(os.getenv("GATE_MCP_RATE_LIMIT_BURST"), 10)
    session_regex = os.getenv("GATE_MCP_ALLOWED_SESSION_REGEX") or r"^[a-zA-Z0-9._:-]{1,128}$"
    model_regex = os.getenv("GATE_MCP_ALLOWED_MODEL_REGEX") or r"^[a-zA-Z0-9._:-]{1,128}$"

    token = read_token(token_file)
    if not token:
        print(f"ERROR: gate MCP token missing from {token_file}")
        return 2

    try:
        session_pattern = re.compile(session_regex)
    except re.error:
        print(f"ERROR: invalid GATE_MCP_ALLOWED_SESSION_REGEX: {session_regex}")
        return 2
    try:
        model_pattern = re.compile(model_regex)
    except re.error:
        print(f"ERROR: invalid GATE_MCP_ALLOWED_MODEL_REGEX: {model_regex}")
        return 2

    cfg = ServiceConfig(
        token=token,
        audit_log=audit_log,
        session_pattern=session_pattern,
        model_pattern=model_pattern,
        rate_limiter=TokenBucketLimiter(rate_per_second=rate_per_second, burst=burst),
        gate=GateClient(base_url=gate_url, timeout_seconds=timeout_seconds),
    )

    server = ThreadingHTTPServer((bind_host, bind_port), GateMCPHandler)
    server.cfg = cfg  # type: ignore[attr-defined]
    print(f"INFO: gate-mcp listening on {bind_host}:{bind_port} (gate={gate_url})")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
