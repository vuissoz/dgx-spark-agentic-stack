#!/usr/bin/env python3
import hashlib
import json
import os
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


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


def configured_models() -> list[str]:
    raw = os.environ.get("TRTLLM_MODELS", "nvfp4-demo")
    models: list[str] = []
    for item in raw.split(","):
        name = item.strip()
        if name:
            models.append(name)
    if not models:
        models.append("nvfp4-demo")
    return models


class Handler(BaseHTTPRequestHandler):
    server_version = "trtllm-skeleton/0.1"

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = env_int("REQUEST_MAX_BYTES", 1048576)
        raw_length = self.headers.get("Content-Length", "0")
        try:
            size = int(raw_length)
        except ValueError:
            raise ValueError("invalid Content-Length")
        if size < 0 or size > length:
            raise ValueError("request payload is too large")
        data = self.rfile.read(size)
        if not data:
            return {}
        payload = json.loads(data.decode("utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("JSON payload must be an object")
        return payload

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._send_json(HTTPStatus.OK, {"status": "ok"})
            return
        if self.path == "/api/tags":
            self._send_json(
                HTTPStatus.OK,
                {"models": [{"name": model} for model in configured_models()]},
            )
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_POST(self) -> None:
        try:
            payload = self._read_json()
        except Exception as exc:
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                {"error": {"message": str(exc), "type": "invalid_request"}},
            )
            return

        if self.path == "/api/chat":
            model = payload.get("model")
            if not isinstance(model, str) or not model:
                model = "nvfp4-demo"
            messages = payload.get("messages")
            message_count = len(messages) if isinstance(messages, list) else 0
            content = f"trtllm synthetic response model={model} messages={message_count}"
            self._send_json(
                HTTPStatus.OK,
                {
                    "model": model,
                    "message": {"role": "assistant", "content": content},
                    "done": True,
                },
            )
            return

        if self.path == "/api/embeddings":
            model = payload.get("model")
            if not isinstance(model, str) or not model:
                model = "nvfp4-demo"
            prompt = payload.get("prompt")
            if not isinstance(prompt, str) or not prompt:
                self._send_json(
                    HTTPStatus.BAD_REQUEST,
                    {
                        "error": {
                            "message": "prompt must be a non-empty string",
                            "type": "invalid_request",
                        }
                    },
                )
                return
            vector = deterministic_embedding_vector(f"{model}:{prompt}")
            self._send_json(HTTPStatus.OK, {"model": model, "embedding": vector})
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def log_message(self, fmt: str, *args: object) -> None:
        return


def main() -> None:
    host = os.environ.get("TRTLLM_LISTEN_HOST", "0.0.0.0")
    port = env_int("TRTLLM_PORT", 11436)
    server = ThreadingHTTPServer((host, port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
