#!/usr/bin/env python3
import argparse
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


def now_ts() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


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


class OptionalHandler(BaseHTTPRequestHandler):
    server_version = "agentic-optional/1.0"

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

    def _read_json_body(self) -> dict[str, Any]:
        size = self.headers.get("Content-Length", "0")
        try:
            length = int(size)
        except ValueError:
            return {}

        raw = self.rfile.read(max(length, 0))
        if not raw:
            return {}
        try:
            decoded = json.loads(raw.decode("utf-8"))
            if isinstance(decoded, dict):
                return decoded
        except json.JSONDecodeError:
            return {}
        return {}

    def _auth_ok(self) -> bool:
        expected = self.cfg["token"]
        if not expected:
            return False
        auth_header = self.headers.get("Authorization", "")
        return auth_header == f"Bearer {expected}"

    def _deny_auth(self, action: str) -> None:
        append_audit(
            self.cfg["audit_log"],
            {
                "ts": now_ts(),
                "module": self.cfg["mode"],
                "action": action,
                "decision": "deny",
                "reason": "invalid_or_missing_token",
                "remote": self.client_address[0],
            },
        )
        self._json_response(401, {"error": "unauthorized"})

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._json_response(200, {"mode": self.cfg["mode"], "status": "ok"})
            return

        self._json_response(404, {"error": "not_found"})

    def do_POST(self) -> None:
        if self.cfg["mode"] == "openclaw":
            self._handle_openclaw_dm()
            return
        if self.cfg["mode"] == "mcp":
            self._handle_mcp_execute()
            return

        self._json_response(404, {"error": "not_found"})

    def _handle_openclaw_dm(self) -> None:
        if self.path != "/v1/dm":
            self._json_response(404, {"error": "not_found"})
            return

        if not self._auth_ok():
            self._deny_auth("send_dm")
            return

        payload = self._read_json_body()
        target = str(payload.get("target", "")).strip()
        message = str(payload.get("message", "")).strip()

        allowlist = self.cfg["allowlist"]
        if target not in allowlist:
            append_audit(
                self.cfg["audit_log"],
                {
                    "ts": now_ts(),
                    "module": "openclaw",
                    "action": "send_dm",
                    "decision": "deny",
                    "reason": "target_not_allowlisted",
                    "target": target,
                },
            )
            self._json_response(403, {"error": "target_not_allowlisted"})
            return

        append_audit(
            self.cfg["audit_log"],
            {
                "ts": now_ts(),
                "module": "openclaw",
                "action": "send_dm",
                "decision": "allow",
                "target": target,
                "message_len": len(message),
            },
        )
        self._json_response(202, {"status": "queued", "target": target})

    def _handle_mcp_execute(self) -> None:
        if self.path != "/v1/tools/execute":
            self._json_response(404, {"error": "not_found"})
            return

        if not self._auth_ok():
            self._deny_auth("execute_tool")
            return

        payload = self._read_json_body()
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
                    "tool": tool,
                },
            )
            self._json_response(403, {"error": "tool_not_allowlisted"})
            return

        append_audit(
            self.cfg["audit_log"],
            {
                "ts": now_ts(),
                "module": "mcp",
                "action": "execute_tool",
                "decision": "allow",
                "tool": tool,
            },
        )
        self._json_response(200, {"status": "allowed", "tool": tool})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Agentic optional module service")
    parser.add_argument("mode", choices=["openclaw", "mcp"])
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    bind_host = os.environ.get("OPTIONAL_BIND_HOST", "0.0.0.0")
    bind_port = int(os.environ.get("OPTIONAL_BIND_PORT", "8111"))
    audit_log = os.environ.get("AUDIT_LOG_PATH", "/logs/audit.jsonl")

    if args.mode == "openclaw":
        token_file = os.environ.get("OPENCLAW_AUTH_TOKEN_FILE", "/run/secrets/openclaw.token")
        allowlist_file = os.environ.get("OPENCLAW_DM_ALLOWLIST_FILE", "/config/dm_allowlist.txt")
    else:
        token_file = os.environ.get("MCP_AUTH_TOKEN_FILE", "/run/secrets/mcp.token")
        allowlist_file = os.environ.get("MCP_ALLOWLIST_FILE", "/config/tool_allowlist.txt")

    cfg = {
        "mode": args.mode,
        "token": read_token(token_file),
        "allowlist": read_list_file(allowlist_file),
        "audit_log": audit_log,
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
