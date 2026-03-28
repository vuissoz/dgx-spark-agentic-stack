#!/usr/bin/env python3
import hashlib
import json
import os
import re
import time
import uuid
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


DEFAULT_TRTLLM_MODEL = "https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4"


def configured_models() -> list[str]:
    raw = os.environ.get("TRTLLM_MODELS", DEFAULT_TRTLLM_MODEL)
    models: list[str] = []
    for item in raw.split(","):
        name = item.strip()
        if name:
            models.append(name)
    if not models:
        models.append(DEFAULT_TRTLLM_MODEL)
    return models


WORKSPACE_PATH_RE = re.compile(r"(/workspace/[^\s\"'<>]+)")


def first_workspace_path(messages: object) -> str:
    if not isinstance(messages, list):
        return "/workspace/README.md"
    for message in reversed(messages):
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if isinstance(content, str):
            match = WORKSPACE_PATH_RE.search(content)
            if match:
                return match.group(1)
    return "/workspace/README.md"


def normalize_function_tool(value: object) -> dict | None:
    if not isinstance(value, dict):
        return None
    function = value.get("function")
    if not isinstance(function, dict):
        return None
    name = function.get("name")
    if not isinstance(name, str) or not name.strip():
        return None
    parameters = function.get("parameters")
    if not isinstance(parameters, dict):
        parameters = {}
    return {
        "name": name.strip(),
        "parameters": parameters,
    }


def choose_tool(payload: dict) -> dict | None:
    tools_raw = payload.get("tools")
    tools: list[dict] = []
    if isinstance(tools_raw, list):
        for item in tools_raw:
            normalized = normalize_function_tool(item)
            if normalized is not None:
                tools.append(normalized)
    if not tools:
        return None

    tool_choice = payload.get("tool_choice")
    selected_name = None
    if isinstance(tool_choice, dict):
        function = tool_choice.get("function")
        if isinstance(function, dict):
            name = function.get("name")
            if isinstance(name, str) and name.strip():
                selected_name = name.strip()

    if selected_name:
        for tool in tools:
            if tool["name"] == selected_name:
                return tool

    return tools[0]


def synthetic_tool_arguments(tool_name: str, parameters: dict, messages: object) -> dict:
    properties = parameters.get("properties")
    if not isinstance(properties, dict):
        properties = {}

    arguments: dict[str, object] = {}
    for key in properties:
        if key == "path":
            arguments[key] = first_workspace_path(messages)
        elif key == "command":
            arguments[key] = "pwd"
        elif key == "description":
            arguments[key] = f"trtllm synthetic tool call for {tool_name}"
        elif key == "tool":
            arguments[key] = tool_name
        elif key == "check":
            arguments[key] = "tool_call"
        else:
            arguments[key] = key

    required = parameters.get("required")
    if isinstance(required, list):
        for key in required:
            if not isinstance(key, str) or key in arguments:
                continue
            if key == "path":
                arguments[key] = first_workspace_path(messages)
            else:
                arguments[key] = key

    return arguments


def synthetic_tool_call_payload(payload: dict) -> dict | None:
    tool = choose_tool(payload)
    if tool is None:
        return None

    arguments = synthetic_tool_arguments(
        tool_name=tool["name"],
        parameters=tool["parameters"],
        messages=payload.get("messages"),
    )
    return {
        "id": f"call_{uuid.uuid4().hex[:12]}",
        "type": "function",
        "function": {
            "name": tool["name"],
            "arguments": json.dumps(arguments, ensure_ascii=True, separators=(",", ":")),
        },
    }


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
        if self.path == "/v1/models":
            self._send_json(
                HTTPStatus.OK,
                {
                    "object": "list",
                    "data": [
                        {"id": model, "object": "model", "owned_by": "trtllm"}
                        for model in configured_models()
                    ],
                },
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
            tool_call = synthetic_tool_call_payload(payload)
            if tool_call is not None:
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "model": model,
                        "message": {
                            "role": "assistant",
                            "content": "",
                            "tool_calls": [tool_call],
                        },
                        "done": True,
                        "done_reason": "tool_calls",
                    },
                )
                return
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

        if self.path == "/v1/chat/completions":
            model = payload.get("model")
            if not isinstance(model, str) or not model:
                model = "nvfp4-demo"
            messages = payload.get("messages")
            message_count = len(messages) if isinstance(messages, list) else 0
            tool_call = synthetic_tool_call_payload(payload)
            message = {"role": "assistant", "content": f"trtllm synthetic response model={model} messages={message_count}"}
            finish_reason = "stop"
            if tool_call is not None:
                message = {"role": "assistant", "content": "", "tool_calls": [tool_call]}
                finish_reason = "tool_calls"
            self._send_json(
                HTTPStatus.OK,
                {
                    "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
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
                    "usage": {
                        "prompt_tokens": 0,
                        "completion_tokens": 0,
                        "total_tokens": 0,
                    },
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
