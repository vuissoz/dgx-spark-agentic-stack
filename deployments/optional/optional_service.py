#!/usr/bin/env python3
import argparse
import hashlib
import hmac
import json
import os
import re
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")


def now_ts() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def epoch_now() -> int:
    return int(time.time())


def read_token(path: str) -> str:
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return ""


def read_list_file(path: str) -> set[str]:
    entries: set[str] = set()
    try:
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            item = line.strip()
            if not item or item.startswith("#"):
                continue
            entries.add(item)
    except FileNotFoundError:
        pass
    return entries


def append_audit(path: str, payload: dict[str, Any]) -> None:
    log_path = Path(path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n")


def decode_json_bytes(raw: bytes) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        decoded = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}
    if isinstance(decoded, dict):
        return decoded
    return {}


def read_json_object_file(path: str) -> dict[str, Any]:
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise ValueError(f"openclaw profile file is missing: {path}") from exc

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"openclaw profile file is not valid JSON: {path}") from exc

    if not isinstance(payload, dict):
        raise ValueError(f"openclaw profile must be a JSON object: {path}")

    return payload


def parse_string_set(value: Any, field_name: str, default: list[str]) -> set[str]:
    source = value
    if source is None:
        source = default

    if not isinstance(source, list):
        raise ValueError(f"openclaw profile field must be an array: {field_name}")

    parsed: set[str] = set()
    for item in source:
        if not isinstance(item, str):
            continue
        text = item.strip()
        if not text:
            continue
        parsed.add(text)

    if not parsed:
        raise ValueError(f"openclaw profile field cannot be empty: {field_name}")
    return parsed


def load_openclaw_profile(path: str, mode: str) -> dict[str, Any]:
    profile = read_json_object_file(path)

    profile_id = str(profile.get("profile_id", "")).strip()
    profile_version = str(profile.get("profile_version", "")).strip()
    if not profile_id:
        raise ValueError("openclaw profile is missing profile_id")
    if not profile_version:
        raise ValueError("openclaw profile is missing profile_version")

    runtime = profile.get("runtime")
    if not isinstance(runtime, dict):
        raise ValueError("openclaw profile is missing runtime section")

    auth = runtime.get("auth")
    if not isinstance(auth, dict):
        auth = {}

    required_env = runtime.get("required_env")
    required_env_entries: Any = []
    if isinstance(required_env, dict):
        env_key = "openclaw_sandbox" if mode == "openclaw-sandbox" else "openclaw"
        required_env_entries = required_env.get(env_key, [])
    required_env_set = parse_string_set(required_env_entries, "runtime.required_env", default=[])

    endpoints = runtime.get("endpoints")
    if not isinstance(endpoints, dict):
        raise ValueError("openclaw profile is missing runtime.endpoints section")

    default_health = ["/healthz"]
    default_profile = ["/v1/profile", "/v1/capabilities"]
    default_sandbox_health = ["/v1/sandbox/health"]
    default_dm = ["/v1/dm"]
    default_webhook_dm = ["/v1/webhooks/dm"]
    default_tool_execute = ["/v1/tools/execute"]
    default_sandbox_execute = ["/v1/tools/execute"]

    parsed_endpoints = {
        "health": parse_string_set(endpoints.get("health"), "runtime.endpoints.health", default_health),
        "profile": parse_string_set(endpoints.get("profile"), "runtime.endpoints.profile", default_profile),
        "sandbox_health": parse_string_set(
            endpoints.get("sandbox_health"),
            "runtime.endpoints.sandbox_health",
            default_sandbox_health,
        ),
        "dm": parse_string_set(endpoints.get("dm"), "runtime.endpoints.dm", default_dm),
        "webhook_dm": parse_string_set(
            endpoints.get("webhook_dm"),
            "runtime.endpoints.webhook_dm",
            default_webhook_dm,
        ),
        "tool_execute": parse_string_set(
            endpoints.get("tool_execute"),
            "runtime.endpoints.tool_execute",
            default_tool_execute,
        ),
        "sandbox_execute": parse_string_set(
            endpoints.get("sandbox_execute"),
            "runtime.endpoints.sandbox_execute",
            default_sandbox_execute,
        ),
    }

    for endpoint_group in parsed_endpoints.values():
        for endpoint_path in endpoint_group:
            if not endpoint_path.startswith("/"):
                raise ValueError(f"openclaw profile endpoint must start with '/': {endpoint_path}")

    sandbox_policy = runtime.get("sandbox_policy")
    if not isinstance(sandbox_policy, dict):
        sandbox_policy = {}

    capabilities = parse_string_set(runtime.get("capabilities"), "runtime.capabilities", default=[])

    upstream_contract = profile.get("upstream_contract")
    if not isinstance(upstream_contract, dict):
        upstream_contract = {}

    launch_commands = parse_string_set(
        upstream_contract.get("upstream_launch_commands"),
        "upstream_contract.upstream_launch_commands",
        ["ollama launch openclaw", "ollama launch openclaw --config"],
    )

    upstream_doc_url = str(upstream_contract.get("upstream_doc_url", "")).strip()
    recommended_context_tokens = int(upstream_contract.get("recommended_context_tokens_min", 0) or 0)

    profile_hash = hashlib.sha256(
        json.dumps(profile, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()

    return {
        "profile_id": profile_id,
        "profile_version": profile_version,
        "profile_hash": profile_hash,
        "upstream_doc_url": upstream_doc_url,
        "launch_commands": launch_commands,
        "recommended_context_tokens_min": recommended_context_tokens,
        "required_env": required_env_set,
        "endpoints": parsed_endpoints,
        "capabilities": capabilities,
        "require_proxy_env": bool(sandbox_policy.get("require_proxy_env", False)),
        "tool_allowlist_required": bool(sandbox_policy.get("tool_allowlist_required", False)),
        "bearer_token_required": bool(auth.get("bearer_token_required", True)),
        "webhook_hmac_sha256_required": bool(auth.get("webhook_hmac_sha256_required", True)),
        "webhook_signature_header": str(auth.get("webhook_signature_header", "X-Webhook-Signature")).strip()
        or "X-Webhook-Signature",
        "webhook_timestamp_header": str(auth.get("webhook_timestamp_header", "X-Webhook-Timestamp")).strip()
        or "X-Webhook-Timestamp",
        "webhook_max_skew_sec_default": int(auth.get("webhook_max_skew_sec_default", 300) or 300),
    }


class OptionalHandler(BaseHTTPRequestHandler):
    server_version = "agentic-optional/2.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        # Access logs are captured via explicit audit entries to keep logs structured.
        return

    @property
    def cfg(self) -> dict[str, Any]:
        return self.server.cfg  # type: ignore[attr-defined]

    def _json_response(self, code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body_bytes(self) -> bytes:
        size = self.headers.get("Content-Length", "0")
        try:
            length = int(size)
        except ValueError:
            return b""
        return self.rfile.read(max(length, 0))

    def _request_id(self, payload: dict[str, Any] | None = None) -> str:
        payload = payload or {}
        rid = str(payload.get("request_id", "")).strip()
        if rid and REQUEST_ID_RE.match(rid):
            return rid

        rid = self.headers.get("X-Request-ID", "").strip()
        if rid and REQUEST_ID_RE.match(rid):
            return rid

        return uuid.uuid4().hex

    def _auth_ok(self, expected_token: str | None = None) -> bool:
        expected = expected_token if expected_token is not None else self.cfg.get("token", "")
        if not bool(self.cfg.get("bearer_token_required", True)):
            return True
        if not expected:
            return False
        auth_header = self.headers.get("Authorization", "")
        return auth_header == f"Bearer {expected}"

    def _deny_auth(self, action: str, request_id: str, module: str | None = None) -> None:
        append_audit(
            self.cfg["audit_log"],
            {
                "ts": now_ts(),
                "module": module or self.cfg["mode"],
                "action": action,
                "decision": "deny",
                "reason": "invalid_or_missing_token",
                "request_id": request_id,
                "remote": self.client_address[0],
            },
        )
        self._json_response(401, {"error": "unauthorized", "request_id": request_id})

    def _verify_webhook_signature(self, raw: bytes) -> tuple[bool, str]:
        secret = self.cfg.get("webhook_secret", "")
        if not secret:
            return False, "webhook_secret_missing"

        ts_header_name = str(self.cfg.get("webhook_timestamp_header", "X-Webhook-Timestamp"))
        sig_header_name = str(self.cfg.get("webhook_signature_header", "X-Webhook-Signature"))
        ts_header = self.headers.get(ts_header_name, "").strip()
        sig_header = self.headers.get(sig_header_name, "").strip()
        if not ts_header or not sig_header:
            return False, "missing_webhook_signature_headers"

        try:
            ts_value = int(ts_header)
        except ValueError:
            return False, "invalid_webhook_timestamp"

        max_skew = int(self.cfg.get("webhook_max_skew_sec", 300))
        if abs(epoch_now() - ts_value) > max_skew:
            return False, "webhook_timestamp_skew"

        canonical = f"{ts_header}.".encode("utf-8") + raw
        digest = hmac.new(secret.encode("utf-8"), canonical, hashlib.sha256).hexdigest()
        expected_sig = f"sha256={digest}"
        if not hmac.compare_digest(sig_header, expected_sig):
            return False, "invalid_webhook_signature"

        return True, "ok"

    def _sandbox_health(self) -> tuple[bool, str]:
        url = str(self.cfg.get("sandbox_health_url", "")).strip()
        timeout = float(self.cfg.get("sandbox_timeout_sec", 3.0))

        if not url:
            return False, "sandbox_health_url_missing"

        req = urllib.request.Request(url, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status != 200:
                    return False, f"sandbox_health_http_{resp.status}"
                return True, "sandbox_reachable"
        except urllib.error.HTTPError as exc:
            return False, f"sandbox_health_http_{exc.code}"
        except urllib.error.URLError as exc:
            return False, f"sandbox_health_error:{exc.reason}"
        except TimeoutError:
            return False, "sandbox_health_timeout"

    def _forward_to_sandbox(self, request_id: str, tool: str, args: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        execute_url = str(self.cfg.get("sandbox_execute_url", "")).strip()
        timeout = float(self.cfg.get("sandbox_timeout_sec", 3.0))
        sandbox_token = str(self.cfg.get("sandbox_token", "")).strip()

        if not execute_url:
            return 503, {"error": "sandbox_execute_url_missing", "request_id": request_id}
        if not sandbox_token:
            return 503, {"error": "sandbox_auth_token_missing", "request_id": request_id}

        body = json.dumps(
            {
                "request_id": request_id,
                "tool": tool,
                "args": args,
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")

        req = urllib.request.Request(
            execute_url,
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {sandbox_token}",
                "Content-Type": "application/json",
                "X-Request-ID": request_id,
            },
        )

        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                payload = decode_json_bytes(resp.read())
                if not payload:
                    payload = {"status": "ok", "request_id": request_id}
                payload.setdefault("request_id", request_id)
                return resp.status, payload
        except urllib.error.HTTPError as exc:
            payload = decode_json_bytes(exc.read())
            if not payload:
                payload = {"error": "sandbox_http_error", "status": exc.code, "request_id": request_id}
            payload.setdefault("request_id", request_id)
            return exc.code, payload
        except urllib.error.URLError as exc:
            return 503, {
                "error": "sandbox_unreachable",
                "detail": str(exc.reason),
                "request_id": request_id,
            }
        except TimeoutError:
            return 504, {"error": "sandbox_timeout", "request_id": request_id}

    def do_GET(self) -> None:
        health_paths = self.cfg.get("endpoint_health_paths", {"/healthz"})
        if self.path in health_paths:
            if self.cfg["mode"] == "openclaw":
                sandbox_ok, sandbox_reason = self._sandbox_health()
                if sandbox_ok:
                    self._json_response(200, {"mode": "openclaw", "sandbox": "reachable", "status": "ok"})
                else:
                    self._json_response(
                        503,
                        {
                            "mode": "openclaw",
                            "reason": sandbox_reason,
                            "sandbox": "unreachable",
                            "status": "degraded",
                        },
                    )
                return

            self._json_response(200, {"mode": self.cfg["mode"], "status": "ok"})
            return

        if self.path in self.cfg.get("endpoint_sandbox_health_paths", {"/v1/sandbox/health"}) and self.cfg["mode"] == "openclaw":
            sandbox_ok, sandbox_reason = self._sandbox_health()
            if sandbox_ok:
                self._json_response(200, {"sandbox": "reachable", "status": "ok"})
            else:
                self._json_response(503, {"error": "sandbox_unreachable", "reason": sandbox_reason})
            return

        if self.path in self.cfg.get("endpoint_profile_paths", set()) and self.cfg["mode"] == "openclaw":
            self._json_response(
                200,
                {
                    "capabilities": sorted(self.cfg.get("capabilities", set())),
                    "endpoints": {
                        "dm": sorted(self.cfg.get("endpoint_dm_paths", set())),
                        "profile": sorted(self.cfg.get("endpoint_profile_paths", set())),
                        "sandbox_execute": sorted(self.cfg.get("endpoint_sandbox_execute_paths", set())),
                        "sandbox_health": sorted(self.cfg.get("endpoint_sandbox_health_paths", set())),
                        "tool_execute": sorted(self.cfg.get("endpoint_tool_execute_paths", set())),
                        "webhook_dm": sorted(self.cfg.get("endpoint_webhook_dm_paths", set())),
                    },
                    "launch_commands": sorted(self.cfg.get("launch_commands", set())),
                    "profile_hash": self.cfg.get("profile_hash", ""),
                    "profile_id": self.cfg.get("profile_id", ""),
                    "profile_version": self.cfg.get("profile_version", ""),
                    "recommended_context_tokens_min": self.cfg.get("recommended_context_tokens_min", 0),
                    "upstream_doc_url": self.cfg.get("upstream_doc_url", ""),
                },
            )
            return

        self._json_response(404, {"error": "not_found"})

    def do_POST(self) -> None:
        if self.cfg["mode"] == "openclaw":
            if self.path in self.cfg.get("endpoint_dm_paths", {"/v1/dm"}):
                self._handle_openclaw_dm()
                return
            if self.path in self.cfg.get("endpoint_webhook_dm_paths", {"/v1/webhooks/dm"}):
                self._handle_openclaw_webhook_dm()
                return
            if self.path in self.cfg.get("endpoint_tool_execute_paths", {"/v1/tools/execute"}):
                self._handle_openclaw_tool_execute()
                return
            self._json_response(404, {"error": "not_found"})
            return

        if self.cfg["mode"] == "openclaw-sandbox":
            self._handle_openclaw_sandbox_execute()
            return

        if self.cfg["mode"] == "mcp":
            self._handle_mcp_execute()
            return

        self._json_response(404, {"error": "not_found"})

    def _handle_openclaw_dm_payload(
        self,
        payload: dict[str, Any],
        request_id: str,
        action: str,
        source: str,
    ) -> None:
        target = str(payload.get("target", "")).strip()
        message = str(payload.get("message", "")).strip()

        if not target or not message:
            append_audit(
                self.cfg["audit_log"],
                {
                    "ts": now_ts(),
                    "module": "openclaw",
                    "action": action,
                    "decision": "deny",
                    "reason": "invalid_payload",
                    "request_id": request_id,
                    "source": source,
                    "target": target,
                },
            )
            self._json_response(400, {"error": "invalid_payload", "request_id": request_id})
            return

        allowlist = self.cfg["dm_allowlist"]
        if target not in allowlist:
            append_audit(
                self.cfg["audit_log"],
                {
                    "ts": now_ts(),
                    "module": "openclaw",
                    "action": action,
                    "decision": "deny",
                    "reason": "target_not_allowlisted",
                    "request_id": request_id,
                    "source": source,
                    "target": target,
                },
            )
            self._json_response(403, {"error": "target_not_allowlisted", "request_id": request_id})
            return

        append_audit(
            self.cfg["audit_log"],
            {
                "ts": now_ts(),
                "module": "openclaw",
                "action": action,
                "decision": "allow",
                "request_id": request_id,
                "source": source,
                "target": target,
                "message_len": len(message),
            },
        )
        self._json_response(202, {"request_id": request_id, "status": "queued", "target": target})

    def _handle_openclaw_dm(self) -> None:
        request_id = self._request_id()
        if not self._auth_ok():
            self._deny_auth("send_dm", request_id, module="openclaw")
            return

        payload = decode_json_bytes(self._read_body_bytes())
        self._handle_openclaw_dm_payload(payload, request_id, action="send_dm", source="api")

    def _handle_openclaw_webhook_dm(self) -> None:
        request_id = self._request_id()
        if not self._auth_ok():
            self._deny_auth("webhook_dm", request_id, module="openclaw")
            return

        raw = self._read_body_bytes()
        sig_ok, sig_reason = self._verify_webhook_signature(raw)
        if not sig_ok:
            append_audit(
                self.cfg["audit_log"],
                {
                    "ts": now_ts(),
                    "module": "openclaw",
                    "action": "webhook_dm",
                    "decision": "deny",
                    "reason": sig_reason,
                    "request_id": request_id,
                },
            )
            self._json_response(403, {"error": sig_reason, "request_id": request_id})
            return

        payload = decode_json_bytes(raw)
        self._handle_openclaw_dm_payload(payload, request_id, action="webhook_dm", source="webhook")

    def _handle_openclaw_tool_execute(self) -> None:
        request_id = self._request_id()
        if not self._auth_ok():
            self._deny_auth("execute_tool", request_id, module="openclaw")
            return

        payload = decode_json_bytes(self._read_body_bytes())
        tool = str(payload.get("tool", "")).strip()
        args = payload.get("args", {})
        if not isinstance(args, dict):
            args = {}

        if not tool:
            self._json_response(400, {"error": "tool_required", "request_id": request_id})
            return

        tool_allowlist = self.cfg.get("tool_allowlist", set())
        if tool_allowlist and tool not in tool_allowlist:
            append_audit(
                self.cfg["audit_log"],
                {
                    "ts": now_ts(),
                    "module": "openclaw",
                    "action": "execute_tool",
                    "decision": "deny",
                    "reason": "tool_not_allowlisted",
                    "request_id": request_id,
                    "tool": tool,
                },
            )
            self._json_response(403, {"error": "tool_not_allowlisted", "request_id": request_id})
            return

        sandbox_ok, sandbox_reason = self._sandbox_health()
        if not sandbox_ok:
            append_audit(
                self.cfg["audit_log"],
                {
                    "ts": now_ts(),
                    "module": "openclaw",
                    "action": "execute_tool",
                    "decision": "deny",
                    "reason": "sandbox_unreachable",
                    "request_id": request_id,
                    "tool": tool,
                    "detail": sandbox_reason,
                },
            )
            self._json_response(
                503,
                {
                    "error": "sandbox_unreachable",
                    "detail": sandbox_reason,
                    "request_id": request_id,
                },
            )
            return

        status_code, sandbox_payload = self._forward_to_sandbox(request_id, tool, args)
        decision = "allow" if status_code == 200 else "deny"

        audit_payload: dict[str, Any] = {
            "ts": now_ts(),
            "module": "openclaw",
            "action": "execute_tool",
            "decision": decision,
            "request_id": request_id,
            "tool": tool,
            "sandbox_status": status_code,
        }
        if status_code != 200:
            audit_payload["reason"] = str(sandbox_payload.get("error", "sandbox_execution_failed"))

        append_audit(self.cfg["audit_log"], audit_payload)
        self._json_response(status_code, sandbox_payload)

    def _execute_sandbox_tool(self, tool: str, args: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        if tool == "diagnostics.ping":
            return 200, {"output": "pong", "status": "executed", "tool": tool}

        if tool == "diagnostics.echo":
            message = str(args.get("message", ""))
            return 200, {"output": message[:512], "status": "executed", "tool": tool}

        if tool == "time.now_utc":
            return 200, {"output": now_ts(), "status": "executed", "tool": tool}

        return 501, {"error": "tool_not_implemented", "tool": tool}

    def _handle_openclaw_sandbox_execute(self) -> None:
        if self.path not in self.cfg.get("endpoint_sandbox_execute_paths", {"/v1/tools/execute"}):
            self._json_response(404, {"error": "not_found"})
            return

        payload = decode_json_bytes(self._read_body_bytes())
        request_id = self._request_id(payload)

        if not self._auth_ok(expected_token=self.cfg.get("token", "")):
            self._deny_auth("execute_tool", request_id, module="openclaw-sandbox")
            return

        tool = str(payload.get("tool", "")).strip()
        args = payload.get("args", {})
        if not isinstance(args, dict):
            args = {}

        allowlist = self.cfg["allowlist"]
        if tool not in allowlist:
            append_audit(
                self.cfg["audit_log"],
                {
                    "ts": now_ts(),
                    "module": "openclaw-sandbox",
                    "action": "execute_tool",
                    "decision": "deny",
                    "reason": "tool_not_allowlisted",
                    "request_id": request_id,
                    "tool": tool,
                },
            )
            self._json_response(403, {"error": "tool_not_allowlisted", "request_id": request_id})
            return

        status_code, payload_out = self._execute_sandbox_tool(tool, args)
        decision = "allow" if status_code == 200 else "deny"
        audit_payload: dict[str, Any] = {
            "ts": now_ts(),
            "module": "openclaw-sandbox",
            "action": "execute_tool",
            "decision": decision,
            "request_id": request_id,
            "tool": tool,
            "status_code": status_code,
        }
        if status_code != 200:
            audit_payload["reason"] = str(payload_out.get("error", "execution_failed"))

        append_audit(self.cfg["audit_log"], audit_payload)
        payload_out.setdefault("request_id", request_id)
        self._json_response(status_code, payload_out)

    def _handle_mcp_execute(self) -> None:
        if self.path != "/v1/tools/execute":
            self._json_response(404, {"error": "not_found"})
            return

        request_id = self._request_id()
        if not self._auth_ok():
            self._deny_auth("execute_tool", request_id)
            return

        payload = decode_json_bytes(self._read_body_bytes())
        tool = str(payload.get("tool", "")).strip()

        allowlist = self.cfg["allowlist"]
        if tool not in allowlist:
            append_audit(
                self.cfg["audit_log"],
                {
                    "ts": now_ts(),
                    "module": "mcp",
                    "action": "execute_tool",
                    "decision": "deny",
                    "reason": "tool_not_allowlisted",
                    "request_id": request_id,
                    "tool": tool,
                },
            )
            self._json_response(403, {"error": "tool_not_allowlisted", "request_id": request_id})
            return

        append_audit(
            self.cfg["audit_log"],
            {
                "ts": now_ts(),
                "module": "mcp",
                "action": "execute_tool",
                "decision": "allow",
                "request_id": request_id,
                "tool": tool,
            },
        )
        self._json_response(200, {"request_id": request_id, "status": "allowed", "tool": tool})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Agentic optional module service")
    parser.add_argument("mode", choices=["openclaw", "openclaw-sandbox", "mcp"])
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    default_port_map = {
        "openclaw": "8111",
        "openclaw-sandbox": "8112",
        "mcp": "8122",
    }

    bind_host = os.environ.get("OPTIONAL_BIND_HOST", "0.0.0.0")
    bind_port = int(os.environ.get("OPTIONAL_BIND_PORT", default_port_map[args.mode]))
    audit_log = os.environ.get("AUDIT_LOG_PATH", "/logs/audit.jsonl")

    if args.mode == "openclaw":
        token_file = os.environ.get("OPENCLAW_AUTH_TOKEN_FILE", "/run/secrets/openclaw.token")
        dm_allowlist_file = os.environ.get("OPENCLAW_DM_ALLOWLIST_FILE", "/config/dm_allowlist.txt")
        tool_allowlist_file = os.environ.get("OPENCLAW_TOOL_ALLOWLIST_FILE", "/config/tool_allowlist.txt")
        webhook_secret_file = os.environ.get("OPENCLAW_WEBHOOK_SECRET_FILE", "/run/secrets/openclaw.webhook_secret")
        profile_file = os.environ.get("OPENCLAW_PROFILE_FILE", "/config/integration-profile.current.json")
        sandbox_token_file = os.environ.get("OPENCLAW_SANDBOX_AUTH_TOKEN_FILE", token_file)
        sandbox_base_url = os.environ.get("OPENCLAW_SANDBOX_URL", "http://optional-openclaw-sandbox:8112").rstrip("/")
        sandbox_timeout = float(os.environ.get("OPENCLAW_SANDBOX_TIMEOUT_SEC", "3"))
        try:
            profile_cfg = load_openclaw_profile(profile_file, args.mode)
        except ValueError as exc:
            print(f"ERROR: {exc}")
            return 2

        missing_env = [name for name in sorted(profile_cfg["required_env"]) if not os.environ.get(name)]
        if missing_env:
            print(f"ERROR: openclaw profile missing required environment variables: {','.join(missing_env)}")
            return 2

        if profile_cfg["require_proxy_env"]:
            if not os.environ.get("HTTP_PROXY") or not os.environ.get("HTTPS_PROXY"):
                print("ERROR: openclaw profile requires HTTP_PROXY and HTTPS_PROXY")
                return 2

        webhook_max_skew_default = profile_cfg["webhook_max_skew_sec_default"]
        webhook_max_skew_sec = int(os.environ.get("OPENCLAW_WEBHOOK_MAX_SKEW_SEC", str(webhook_max_skew_default)))
        token_value = read_token(token_file)
        webhook_secret = read_token(webhook_secret_file)
        tool_allowlist = read_list_file(tool_allowlist_file)
        dm_allowlist = read_list_file(dm_allowlist_file)

        cfg = {
            "mode": args.mode,
            "token": token_value,
            "dm_allowlist": dm_allowlist,
            "tool_allowlist": tool_allowlist,
            "webhook_secret": webhook_secret,
            "webhook_max_skew_sec": webhook_max_skew_sec,
            "webhook_signature_header": profile_cfg["webhook_signature_header"],
            "webhook_timestamp_header": profile_cfg["webhook_timestamp_header"],
            "sandbox_timeout_sec": sandbox_timeout,
            "sandbox_token": read_token(sandbox_token_file),
            "sandbox_health_url": f"{sandbox_base_url}/healthz",
            "sandbox_execute_url": f"{sandbox_base_url}/v1/tools/execute",
            "audit_log": audit_log,
            "profile_id": profile_cfg["profile_id"],
            "profile_version": profile_cfg["profile_version"],
            "profile_hash": profile_cfg["profile_hash"],
            "upstream_doc_url": profile_cfg["upstream_doc_url"],
            "launch_commands": profile_cfg["launch_commands"],
            "recommended_context_tokens_min": profile_cfg["recommended_context_tokens_min"],
            "capabilities": profile_cfg["capabilities"],
            "endpoint_health_paths": profile_cfg["endpoints"]["health"],
            "endpoint_profile_paths": profile_cfg["endpoints"]["profile"],
            "endpoint_sandbox_health_paths": profile_cfg["endpoints"]["sandbox_health"],
            "endpoint_dm_paths": profile_cfg["endpoints"]["dm"],
            "endpoint_webhook_dm_paths": profile_cfg["endpoints"]["webhook_dm"],
            "endpoint_tool_execute_paths": profile_cfg["endpoints"]["tool_execute"],
            "endpoint_sandbox_execute_paths": profile_cfg["endpoints"]["sandbox_execute"],
            "bearer_token_required": profile_cfg["bearer_token_required"],
        }

        if not cfg["token"]:
            print(f"ERROR: token missing from {token_file}")
            return 2
        if profile_cfg["webhook_hmac_sha256_required"] and not cfg["webhook_secret"]:
            print(f"ERROR: webhook secret missing from {webhook_secret_file}")
            return 2
        if profile_cfg["tool_allowlist_required"] and not cfg["tool_allowlist"]:
            print(f"ERROR: openclaw profile requires non-empty tool allowlist: {tool_allowlist_file}")
            return 2

    elif args.mode == "openclaw-sandbox":
        token_file = os.environ.get("OPENCLAW_SANDBOX_AUTH_TOKEN_FILE", "/run/secrets/openclaw.token")
        allowlist_file = os.environ.get("OPENCLAW_SANDBOX_TOOL_ALLOWLIST_FILE", "/config/tool_allowlist.txt")
        profile_file = os.environ.get(
            "OPENCLAW_SANDBOX_PROFILE_FILE",
            os.environ.get("OPENCLAW_PROFILE_FILE", "/config/integration-profile.current.json"),
        )
        try:
            profile_cfg = load_openclaw_profile(profile_file, args.mode)
        except ValueError as exc:
            print(f"ERROR: {exc}")
            return 2

        missing_env = [name for name in sorted(profile_cfg["required_env"]) if not os.environ.get(name)]
        if missing_env:
            print(f"ERROR: openclaw-sandbox profile missing required environment variables: {','.join(missing_env)}")
            return 2

        if profile_cfg["require_proxy_env"]:
            if not os.environ.get("HTTP_PROXY") or not os.environ.get("HTTPS_PROXY"):
                print("ERROR: openclaw-sandbox profile requires HTTP_PROXY and HTTPS_PROXY")
                return 2

        allowlist = read_list_file(allowlist_file)

        cfg = {
            "mode": args.mode,
            "token": read_token(token_file),
            "allowlist": allowlist,
            "audit_log": audit_log,
            "endpoint_health_paths": profile_cfg["endpoints"]["health"],
            "endpoint_sandbox_execute_paths": profile_cfg["endpoints"]["sandbox_execute"],
            "bearer_token_required": profile_cfg["bearer_token_required"],
        }

        if not cfg["token"]:
            print(f"ERROR: sandbox token missing from {token_file}")
            return 2
        if profile_cfg["tool_allowlist_required"] and not cfg["allowlist"]:
            print(f"ERROR: openclaw-sandbox profile requires non-empty tool allowlist: {allowlist_file}")
            return 2

    else:
        token_file = os.environ.get("MCP_AUTH_TOKEN_FILE", "/run/secrets/mcp.token")
        allowlist_file = os.environ.get("MCP_ALLOWLIST_FILE", "/config/tool_allowlist.txt")

        cfg = {
            "mode": args.mode,
            "token": read_token(token_file),
            "allowlist": read_list_file(allowlist_file),
            "audit_log": audit_log,
            "endpoint_health_paths": {"/healthz"},
            "bearer_token_required": True,
        }

        if not cfg["token"]:
            print(f"ERROR: token missing from {token_file}")
            return 2

    server = ThreadingHTTPServer((bind_host, bind_port), OptionalHandler)
    server.cfg = cfg  # type: ignore[attr-defined]
    print(f"INFO: optional module '{args.mode}' listening on {bind_host}:{bind_port}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
