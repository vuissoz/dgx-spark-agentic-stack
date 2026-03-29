#!/usr/bin/env python3
import atexit
import hashlib
import http.client
import json
import os
import re
import shutil
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


DEFAULT_TRTLLM_MODEL = "https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8"
DEFAULT_TRTLLM_MODEL_HANDLE = "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8"
DEFAULT_NVFP4_LOCAL_MODEL_DIR = "/models/trtllm-model"
MODEL_POLICY_AUTO = "auto"
MODEL_POLICY_STRICT_NVFP4_LOCAL_ONLY = "strict-nvfp4-local-only"
HF_URL_PREFIX = "https://huggingface.co/"
WORKSPACE_PATH_RE = re.compile(r"(/workspace/[^\s\"'<>]+)")


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, str(default))
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def prepend_env_path(env: dict[str, str], name: str, segments: list[str]) -> None:
    current = env.get(name, "")
    values: list[str] = []
    for segment in segments:
        cleaned = segment.strip()
        if cleaned and cleaned not in values:
            values.append(cleaned)
    for segment in current.split(":"):
        cleaned = segment.strip()
        if cleaned and cleaned not in values:
            values.append(cleaned)
    env[name] = ":".join(values)


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


def strip_hf_url(value: str) -> str:
    candidate = value.strip().rstrip("/")
    if candidate.startswith(HF_URL_PREFIX):
        candidate = candidate[len(HF_URL_PREFIX) :]
    return candidate


def hf_repo_to_url(value: str) -> str:
    normalized = strip_hf_url(value)
    return f"{HF_URL_PREFIX}{normalized}"


def normalize_model_policy(value: str) -> str:
    normalized = value.strip().lower().replace("_", "-") if value else MODEL_POLICY_AUTO
    if normalized in {"", MODEL_POLICY_AUTO}:
        return MODEL_POLICY_AUTO
    if normalized == MODEL_POLICY_STRICT_NVFP4_LOCAL_ONLY:
        return MODEL_POLICY_STRICT_NVFP4_LOCAL_ONLY
    raise ValueError(
        "TRTLLM_NATIVE_MODEL_POLICY must be one of: auto, strict-nvfp4-local-only"
    )


def build_alias_values(display_name: str, requested_handle: str, serve_handle: str) -> tuple[str, ...]:
    alias_values = {display_name, requested_handle, serve_handle}
    for candidate in (requested_handle, serve_handle):
        if not candidate:
            continue
        alias_values.add(f"trtllm/{candidate}")
        if not candidate.startswith("/"):
            alias_values.add(f"{HF_URL_PREFIX}{candidate}")
    catalog_alias = friendly_catalog_alias(display_name, requested_handle, serve_handle)
    if catalog_alias:
        alias_values.add(catalog_alias)
    return tuple(sorted(alias for alias in alias_values if alias))


def friendly_catalog_alias(display_name: str, requested_handle: str, serve_handle: str) -> str | None:
    for raw_candidate in (requested_handle, strip_hf_url(display_name), serve_handle):
        candidate = raw_candidate.strip().rstrip("/") if isinstance(raw_candidate, str) else ""
        if not candidate:
            continue
        if candidate.startswith("/"):
            candidate = candidate.split("/")[-1]
        else:
            candidate = candidate.split("/")[-1]
        normalized = re.sub(r"[^a-z0-9]+", "-", candidate.lower()).strip("-")
        if normalized:
            return f"trtllm/{normalized}"
    return None


def catalog_names_for_entry(entry: "ModelEntry") -> list[str]:
    names = [entry.display_name]
    friendly_alias = friendly_catalog_alias(entry.display_name, entry.requested_handle, entry.serve_handle)
    if friendly_alias and friendly_alias not in names:
        names.append(friendly_alias)
    return names


def model_serve_handle(
    model: str,
    native_model_policy: str = MODEL_POLICY_AUTO,
    nvfp4_local_model_dir: str = DEFAULT_NVFP4_LOCAL_MODEL_DIR,
    strict_expected_handle: str = DEFAULT_TRTLLM_MODEL_HANDLE,
) -> str:
    normalized = strip_hf_url(model)
    if native_model_policy == MODEL_POLICY_STRICT_NVFP4_LOCAL_ONLY and normalized == strict_expected_handle:
        return nvfp4_local_model_dir.rstrip("/") or nvfp4_local_model_dir
    return normalized


@dataclass(frozen=True)
class ModelEntry:
    display_name: str
    requested_handle: str
    serve_handle: str
    aliases: tuple[str, ...]


def build_model_entries(
    raw_models: str,
    native_model_policy: str = MODEL_POLICY_AUTO,
    nvfp4_local_model_dir: str = DEFAULT_NVFP4_LOCAL_MODEL_DIR,
    strict_expected_handle: str = DEFAULT_TRTLLM_MODEL_HANDLE,
) -> list[ModelEntry]:
    if native_model_policy == MODEL_POLICY_STRICT_NVFP4_LOCAL_ONLY:
        configured = [item.strip() for item in raw_models.split(",") if item.strip()]
        if not configured:
            configured = [DEFAULT_TRTLLM_MODEL]
        if len(configured) != 1:
            raise ValueError(
                "strict NVFP4 local-only mode supports exactly one TRTLLM_MODELS entry"
            )

        display_name = configured[0]
        requested_handle = strip_hf_url(display_name)
        serve_handle = nvfp4_local_model_dir.rstrip("/") or nvfp4_local_model_dir
        if requested_handle not in {strict_expected_handle, serve_handle}:
            raise ValueError(
                "strict NVFP4 local-only mode requires TRTLLM_MODELS to expose "
                f"{hf_repo_to_url(strict_expected_handle)} or {serve_handle}"
            )
        return [
            ModelEntry(
                display_name=display_name,
                requested_handle=requested_handle,
                serve_handle=serve_handle,
                aliases=build_alias_values(display_name, requested_handle, serve_handle),
            )
        ]

    entries: list[ModelEntry] = []
    for item in raw_models.split(","):
        display_name = item.strip()
        if not display_name:
            continue

        requested_handle = strip_hf_url(display_name)
        serve_handle = model_serve_handle(
            display_name,
            native_model_policy=native_model_policy,
            nvfp4_local_model_dir=nvfp4_local_model_dir,
            strict_expected_handle=strict_expected_handle,
        )
        entries.append(
            ModelEntry(
                display_name=display_name,
                requested_handle=requested_handle,
                serve_handle=serve_handle,
                aliases=build_alias_values(display_name, requested_handle, serve_handle),
            )
        )

    if entries:
        return entries

    fallback = strip_hf_url(DEFAULT_TRTLLM_MODEL)
    fallback_serve_handle = model_serve_handle(
        DEFAULT_TRTLLM_MODEL,
        native_model_policy=native_model_policy,
        nvfp4_local_model_dir=nvfp4_local_model_dir,
        strict_expected_handle=strict_expected_handle,
    )
    return [
        ModelEntry(
            display_name=DEFAULT_TRTLLM_MODEL,
            requested_handle=fallback,
            serve_handle=fallback_serve_handle,
            aliases=build_alias_values(DEFAULT_TRTLLM_MODEL, fallback, fallback_serve_handle),
        )
    ]


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
    return {"name": name.strip(), "parameters": parameters}


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


def infer_quantization_level(model_handle: str) -> str | None:
    upper = model_handle.upper()
    for token in ("FP8", "NVFP4", "FP4", "MXFP4"):
        if token in upper:
            return token
    return None


class RuntimeController:
    def __init__(self) -> None:
        self.listen_host = os.environ.get("TRTLLM_LISTEN_HOST", "0.0.0.0")
        self.listen_port = env_int("TRTLLM_PORT", 11436)
        self.runtime_mode_requested = os.environ.get("TRTLLM_RUNTIME_MODE", "auto").strip().lower() or "auto"
        self.native_host = os.environ.get("TRTLLM_NATIVE_HOST", "127.0.0.1")
        self.native_port = env_int("TRTLLM_NATIVE_PORT", 8355)
        self.native_backend = os.environ.get("TRTLLM_NATIVE_BACKEND", "").strip()
        self.native_log_level = os.environ.get("TRTLLM_NATIVE_LOG_LEVEL", "info").strip() or "info"
        self.native_max_batch_size = max(1, env_int("TRTLLM_NATIVE_MAX_BATCH_SIZE", 1))
        self.native_max_num_tokens = max(1, env_int("TRTLLM_NATIVE_MAX_NUM_TOKENS", 4096))
        self.native_max_seq_len = max(self.native_max_num_tokens, env_int("TRTLLM_NATIVE_MAX_SEQ_LEN", 32768))
        self.native_enable_cuda_graph = env_bool("TRTLLM_NATIVE_ENABLE_CUDA_GRAPH", False)
        self.native_cuda_graph_max_batch_size = max(
            self.native_max_batch_size, env_int("TRTLLM_NATIVE_CUDA_GRAPH_MAX_BATCH_SIZE", self.native_max_batch_size)
        )
        self.native_cuda_graph_enable_padding = env_bool("TRTLLM_NATIVE_CUDA_GRAPH_ENABLE_PADDING", False)
        self.native_moe_backend = os.environ.get("TRTLLM_NATIVE_MOE_BACKEND", "CUTLASS").strip() or "CUTLASS"
        self.native_enable_block_reuse = env_bool("TRTLLM_NATIVE_ENABLE_BLOCK_REUSE", False)
        self.native_free_gpu_memory_fraction = env_float("TRTLLM_NATIVE_FREE_GPU_MEMORY_FRACTION", 0.8)
        self.native_start_timeout_seconds = max(5, env_int("TRTLLM_NATIVE_START_TIMEOUT_SECONDS", 7200))
        self.native_model_policy = normalize_model_policy(os.environ.get("TRTLLM_NATIVE_MODEL_POLICY", MODEL_POLICY_AUTO))
        self.strict_nvfp4_local_only = self.native_model_policy == MODEL_POLICY_STRICT_NVFP4_LOCAL_ONLY
        self.hf_token_file = Path(os.environ.get("TRTLLM_HF_TOKEN_FILE", "/run/secrets/huggingface.token"))
        self.models_dir = Path(os.environ.get("TRTLLM_MODELS_DIR", "/models"))
        self.nvfp4_local_model_dir = (
            os.environ.get("TRTLLM_NVFP4_LOCAL_MODEL_DIR", DEFAULT_NVFP4_LOCAL_MODEL_DIR).strip().rstrip("/")
            or DEFAULT_NVFP4_LOCAL_MODEL_DIR
        )
        self.strict_expected_handle = strip_hf_url(
            os.environ.get("TRTLLM_NVFP4_HF_REPO", DEFAULT_TRTLLM_MODEL_HANDLE)
        )
        self.state_dir = Path(os.environ.get("TRTLLM_STATE_DIR", "/state"))
        self.logs_dir = Path(os.environ.get("TRTLLM_LOGS_DIR", "/logs"))
        self.extra_config_file = self.state_dir / "trtllm-extra-llm-api-config.yml"
        self.native_log_file = self.logs_dir / "trtllm-native.log"
        self.runtime_state_file = self.state_dir / "runtime-state.json"
        self.tool_parser = os.environ.get("TRTLLM_TOOL_PARSER", "").strip()
        self.reasoning_parser = os.environ.get("TRTLLM_REASONING_PARSER", "").strip()
        self.trust_remote_code = env_bool("TRTLLM_TRUST_REMOTE_CODE", True)
        self.configuration_error = ""
        try:
            self.entries = build_model_entries(
                os.environ.get("TRTLLM_MODELS", DEFAULT_TRTLLM_MODEL),
                native_model_policy=self.native_model_policy,
                nvfp4_local_model_dir=self.nvfp4_local_model_dir,
                strict_expected_handle=self.strict_expected_handle,
            )
        except ValueError as exc:
            self.configuration_error = str(exc)
            self.entries = build_model_entries(
                hf_repo_to_url(self.strict_expected_handle),
                native_model_policy=self.native_model_policy,
                nvfp4_local_model_dir=self.nvfp4_local_model_dir,
                strict_expected_handle=self.strict_expected_handle,
            )
        self.primary_entry = self.entries[0]
        self.runtime_mode_effective = self._resolve_runtime_mode()
        self.native_proc: subprocess.Popen[str] | None = None
        self.native_ready = False
        self.native_error = ""
        self.native_notice = ""
        self.shutdown_requested = False
        self.lock = threading.Lock()
        self.alias_map: dict[str, ModelEntry] = {}
        for entry in self.entries:
            for alias in entry.aliases:
                self.alias_map[alias] = entry

    def _resolve_runtime_mode(self) -> str:
        if self.runtime_mode_requested in {"mock", "native"}:
            return self.runtime_mode_requested
        if self.strict_nvfp4_local_only:
            return "native"
        if self.primary_entry.serve_handle.startswith("/") and Path(self.primary_entry.serve_handle).exists():
            return "native"
        if self.read_hf_token() and shutil.which("trtllm-serve"):
            return "native"
        return "mock"

    def read_hf_token(self) -> str:
        try:
            return self.hf_token_file.read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    def ensure_runtime_dirs(self) -> None:
        self.models_dir.mkdir(parents=True, exist_ok=True)
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        (self.models_dir / "huggingface").mkdir(parents=True, exist_ok=True)
        (self.state_dir / "home").mkdir(parents=True, exist_ok=True)
        cache_root = self.state_dir / "cache"
        cache_root.mkdir(parents=True, exist_ok=True)
        (cache_root / "tmp").mkdir(parents=True, exist_ok=True)
        (cache_root / "triton").mkdir(parents=True, exist_ok=True)
        (cache_root / "torchinductor").mkdir(parents=True, exist_ok=True)
        (cache_root / "torch_extensions").mkdir(parents=True, exist_ok=True)

    def write_runtime_state(self) -> None:
        payload = {
            "runtime_mode_requested": self.runtime_mode_requested,
            "runtime_mode_effective": self.runtime_mode_effective,
            "native_model_policy": self.native_model_policy,
            "native_ready": self.native_ready,
            "native_error": self.native_error,
            "configuration_error": self.configuration_error,
            "primary_model_requested": self.primary_entry.display_name,
            "primary_model_handle": self.primary_entry.serve_handle,
            "nvfp4_local_model_dir": self.nvfp4_local_model_dir,
            "native_notice": self.native_notice,
            "updated_at_epoch": int(time.time()),
        }
        tmp = self.runtime_state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(tmp, self.runtime_state_file)

    def start(self) -> None:
        self.ensure_runtime_dirs()
        self.write_runtime_state()
        if self.configuration_error:
            return
        if self.runtime_mode_effective == "native":
            self.start_native()

    def stop(self) -> None:
        self.shutdown_requested = True
        proc = self.native_proc
        if proc is None or proc.poll() is not None:
            return
        try:
            proc.terminate()
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
        finally:
            self.native_proc = None
            self.native_ready = False
            self.write_runtime_state()

    def start_native(self) -> None:
        token = self.read_hf_token()
        primary = self.primary_entry

        if not shutil.which("trtllm-serve"):
            self.native_error = "trtllm-serve is not installed in the runtime image"
            self.write_runtime_state()
            return

        if self.strict_nvfp4_local_only:
            local_model_dir = Path(primary.serve_handle)
            if not local_model_dir.is_absolute():
                self.native_error = (
                    "strict NVFP4 local-only mode requires an absolute TRTLLM_NVFP4_LOCAL_MODEL_DIR "
                    f"(got {primary.serve_handle!r})"
                )
                self.write_runtime_state()
                return
            if not local_model_dir.exists():
                self.native_error = (
                    "strict NVFP4 local-only mode requires a prepared local model directory at "
                    f"{local_model_dir}"
                )
                self.write_runtime_state()
                return
        elif "/" in primary.serve_handle and not token and not Path(primary.serve_handle).exists():
            self.native_error = f"HF token missing: create non-empty file {self.hf_token_file} to serve {primary.serve_handle}"
            self.write_runtime_state()
            return

        if self.strict_nvfp4_local_only:
            self.native_notice = (
                f"strict NVFP4 local-only mode serves requested model {primary.requested_handle} "
                f"from local directory {primary.serve_handle}"
            )
        elif primary.requested_handle != primary.serve_handle:
            self.native_notice = (
                f"requested model {primary.requested_handle} is served through Spark-supported handle "
                f"{primary.serve_handle}"
            )
        else:
            self.native_notice = ""

        self.extra_config_file.write_text(self.render_extra_config(), encoding="utf-8")

        env = self.build_native_env(token)

        cmd = self.build_native_command()

        with self.native_log_file.open("a", encoding="utf-8") as fh:
            fh.write(
                f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] starting TRT-LLM native server "
                f"requested={primary.display_name} serve={primary.serve_handle}\n"
            )
            if self.native_notice:
                fh.write(f"[notice] {self.native_notice}\n")
            fh.flush()

        log_handle = self.native_log_file.open("a", encoding="utf-8")
        self.native_proc = subprocess.Popen(
            cmd,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            env=env,
            text=True,
        )

        threading.Thread(target=self._monitor_native_startup, daemon=True).start()
        threading.Thread(target=self._monitor_native_exit, daemon=True).start()

    def render_extra_config(self) -> str:
        extra_config = (
            "print_iter_log: false\n"
            "kv_cache_config:\n"
            f"  enable_block_reuse: {'true' if self.native_enable_block_reuse else 'false'}\n"
            '  dtype: "auto"\n'
            f"  free_gpu_memory_fraction: {self.native_free_gpu_memory_fraction}\n"
            "moe_config:\n"
            f"  backend: {self.native_moe_backend}\n"
            f"  max_num_tokens: {self.native_max_num_tokens}\n"
            "disable_overlap_scheduler: true\n"
        )
        if self.native_enable_cuda_graph:
            extra_config += (
                "cuda_graph_config:\n"
                f"  max_batch_size: {self.native_cuda_graph_max_batch_size}\n"
                f"  enable_padding: {'true' if self.native_cuda_graph_enable_padding else 'false'}\n"
            )
        return extra_config

    def build_native_command(self) -> list[str]:
        primary = self.primary_entry

        cmd = [
            "trtllm-serve",
            "serve",
            primary.serve_handle,
            "--host",
            self.native_host,
            "--port",
            str(self.native_port),
            "--log_level",
            self.native_log_level,
            "--max_batch_size",
            str(self.native_max_batch_size),
            "--max_num_tokens",
            str(self.native_max_num_tokens),
            "--max_seq_len",
            str(self.native_max_seq_len),
            "--config",
            str(self.extra_config_file),
        ]
        effective_backend = self.native_backend or ("" if self.strict_nvfp4_local_only else "pytorch")
        if effective_backend:
            cmd.extend(["--backend", effective_backend])
        if self.trust_remote_code:
            cmd.append("--trust_remote_code")
        if self.tool_parser:
            cmd.extend(["--tool_parser", self.tool_parser])
        if self.reasoning_parser:
            cmd.extend(["--reasoning_parser", self.reasoning_parser])
        return cmd

    def build_native_env(self, token: str = "") -> dict[str, str]:
        env = os.environ.copy()
        cache_root = self.state_dir / "cache"
        env["HOME"] = str(self.state_dir / "home")
        env["HF_HOME"] = str(self.models_dir / "huggingface")
        env["HF_HUB_CACHE"] = str(self.models_dir / "huggingface" / "hub")
        env["TRANSFORMERS_CACHE"] = str(self.models_dir / "huggingface")
        env["XDG_CACHE_HOME"] = str(cache_root)
        env["TMPDIR"] = str(cache_root / "tmp")
        env["TRITON_CACHE_DIR"] = str(cache_root / "triton")
        env["TORCHINDUCTOR_CACHE_DIR"] = str(cache_root / "torchinductor")
        env["TORCH_EXTENSIONS_DIR"] = str(cache_root / "torch_extensions")
        env["NO_PROXY"] = "127.0.0.1,localhost"
        env["no_proxy"] = env["NO_PROXY"]
        prepend_env_path(
            env,
            "LD_LIBRARY_PATH",
            [
                "/opt/nvidia/nvda_nixl/lib/aarch64-linux-gnu",
                "/opt/nvidia/nvda_nixl/lib64",
                "/usr/local/ucx/lib",
                "/usr/local/tensorrt/lib",
                "/usr/local/cuda/lib64",
                "/usr/local/lib/python3.12/dist-packages/torch/lib",
                "/usr/local/lib/python3.12/dist-packages/torch_tensorrt/lib",
                "/usr/local/cuda/compat/lib",
                "/usr/local/nvidia/lib",
                "/usr/local/nvidia/lib64",
            ],
        )
        if token:
            env["HF_TOKEN"] = token
        return env

    def _monitor_native_exit(self) -> None:
        proc = self.native_proc
        if proc is None:
            return
        rc = proc.wait()
        with self.lock:
            if not self.shutdown_requested and rc != 0:
                self.native_error = f"native TRT-LLM server exited with code {rc}; inspect {self.native_log_file}"
            self.native_ready = False
            self.write_runtime_state()

    def _monitor_native_startup(self) -> None:
        deadline = time.time() + self.native_start_timeout_seconds
        while time.time() < deadline:
            if self.shutdown_requested:
                return
            proc = self.native_proc
            if proc is None:
                return
            if proc.poll() is not None:
                with self.lock:
                    if not self.native_error:
                        self.native_error = f"native TRT-LLM server exited early with code {proc.returncode}; inspect {self.native_log_file}"
                    self.write_runtime_state()
                return
            try:
                status, _, _ = self.native_request("GET", "/v1/models")
            except ConnectionError:
                status = 0
            if status == 200:
                with self.lock:
                    self.native_ready = True
                    self.native_error = ""
                    self.write_runtime_state()
                return
            time.sleep(2)

        with self.lock:
            self.native_error = (
                f"native TRT-LLM server did not become ready within {self.native_start_timeout_seconds}s; "
                f"inspect {self.native_log_file}"
            )
            self.write_runtime_state()

    def status_code(self) -> int:
        if self.configuration_error:
            return HTTPStatus.SERVICE_UNAVAILABLE
        if self.runtime_mode_effective == "mock":
            return HTTPStatus.OK
        if not self.native_error:
            return HTTPStatus.OK
        if self.native_ready:
            return HTTPStatus.OK
        return HTTPStatus.SERVICE_UNAVAILABLE

    def request_status_code(self) -> int:
        if self.configuration_error:
            return HTTPStatus.SERVICE_UNAVAILABLE
        if self.runtime_mode_effective == "mock":
            return HTTPStatus.OK
        if self.native_ready:
            return HTTPStatus.OK
        return HTTPStatus.SERVICE_UNAVAILABLE

    def health_payload(self) -> dict:
        status = "ok"
        if self.configuration_error:
            status = "error"
        elif self.runtime_mode_effective == "native" and not self.native_ready:
            status = "starting"
        if self.native_error:
            status = "error"
        payload = {
            "status": status,
            "runtime_mode_requested": self.runtime_mode_requested,
            "runtime_mode_effective": self.runtime_mode_effective,
            "native_model_policy": self.native_model_policy,
            "primary_model_requested": self.primary_entry.display_name,
            "primary_model_handle": self.primary_entry.serve_handle,
            "nvfp4_local_model_dir": self.nvfp4_local_model_dir,
            "native_ready": self.native_ready,
        }
        if self.native_notice:
            payload["notice"] = self.native_notice
        if self.configuration_error:
            payload["error"] = self.configuration_error
        if self.native_error:
            payload["error"] = self.native_error
        return payload

    def available_entries(self) -> list[ModelEntry]:
        if self.runtime_mode_effective != "native":
            return self.entries
        primary_handle = self.primary_entry.serve_handle
        return [entry for entry in self.entries if entry.serve_handle == primary_handle]

    def tags_payload(self) -> dict:
        models = []
        for entry in self.available_entries():
            for catalog_name in catalog_names_for_entry(entry):
                details = {
                    "family": "trtllm",
                    "format": "openai-compatible",
                    "parent_model": entry.serve_handle,
                }
                if catalog_name != entry.display_name:
                    details["canonical_model"] = entry.display_name
                quantization_level = infer_quantization_level(entry.serve_handle)
                if quantization_level:
                    details["quantization_level"] = quantization_level
                models.append(
                    {
                        "name": catalog_name,
                        "modified_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                        "size": 0,
                        "digest": f"trtllm:{entry.serve_handle}",
                        "details": details,
                    }
                )
        return {"models": models}

    def models_payload(self) -> dict:
        data = []
        for entry in self.available_entries():
            for catalog_name in catalog_names_for_entry(entry):
                record = {"id": catalog_name, "object": "model", "owned_by": "trtllm"}
                metadata: dict[str, str] = {}
                if catalog_name != entry.display_name:
                    metadata["canonical_model"] = entry.display_name
                if entry.display_name != entry.serve_handle:
                    metadata["serve_handle"] = entry.serve_handle
                if metadata:
                    record["metadata"] = metadata
                data.append(record)
        return {"object": "list", "data": data}

    def resolve_request_model(self, requested: str | None) -> tuple[str, str]:
        if not isinstance(requested, str) or not requested.strip():
            return self.primary_entry.display_name, self.primary_entry.serve_handle

        candidate = requested.strip()
        entry = self.alias_map.get(candidate)
        if entry is None and candidate.startswith("trtllm/"):
            entry = self.alias_map.get(candidate[len("trtllm/") :])
        if entry is None and self.runtime_mode_effective == "native" and candidate.startswith("trtllm/"):
            return candidate, self.primary_entry.serve_handle
        if entry is None:
            return candidate, self.primary_entry.serve_handle
        if self.runtime_mode_effective == "native" and entry.serve_handle != self.primary_entry.serve_handle:
            raise ValueError(
                f"native TRT-LLM runtime currently serves a single handle ({self.primary_entry.serve_handle}); "
                f"requested alias {candidate!r} resolves to different handle {entry.serve_handle!r}"
            )
        return candidate, entry.serve_handle

    def native_request(self, method: str, path: str, payload: dict | None = None) -> tuple[int, dict | None, str]:
        url = f"http://{self.native_host}:{self.native_port}{path}"
        body = None
        headers = {}
        if payload is not None:
            body = json.dumps(payload, ensure_ascii=True).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read().decode("utf-8")
                parsed = json.loads(raw) if raw else None
                return response.status, parsed, raw
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            parsed = None
            try:
                parsed = json.loads(raw) if raw else None
            except json.JSONDecodeError:
                parsed = None
            return exc.code, parsed, raw
        except Exception as exc:
            raise ConnectionError(str(exc)) from exc


CONTROLLER = RuntimeController()


def mock_chat_completion_payload(model: str, payload: dict) -> dict:
    messages = payload.get("messages")
    message_count = len(messages) if isinstance(messages, list) else 0
    tool_call = synthetic_tool_call_payload(payload)
    message = {"role": "assistant", "content": f"trtllm synthetic response model={model} messages={message_count}"}
    finish_reason = "stop"
    if tool_call is not None:
        message = {"role": "assistant", "content": "", "tool_calls": [tool_call]}
        finish_reason = "tool_calls"
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


def mock_api_chat_payload(model: str, payload: dict) -> dict:
    messages = payload.get("messages")
    message_count = len(messages) if isinstance(messages, list) else 0
    tool_call = synthetic_tool_call_payload(payload)
    if tool_call is not None:
        return {
            "model": model,
            "message": {"role": "assistant", "content": "", "tool_calls": [tool_call]},
            "done": True,
            "done_reason": "tool_calls",
        }
    return {
        "model": model,
        "message": {"role": "assistant", "content": f"trtllm synthetic response model={model} messages={message_count}"},
        "done": True,
    }


def openai_to_ollama_payload(requested_model: str, payload: dict) -> dict:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise ValueError("upstream chat completion payload is missing choices")
    first = choices[0]
    if not isinstance(first, dict):
        raise ValueError("upstream chat completion payload is invalid")
    message = first.get("message")
    if not isinstance(message, dict):
        raise ValueError("upstream chat completion payload is missing message")

    response = {
        "model": requested_model,
        "message": {
            "role": message.get("role", "assistant"),
            "content": message.get("content", "") if isinstance(message.get("content"), str) else "",
        },
        "done": True,
        "done_reason": first.get("finish_reason") or "stop",
    }
    tool_calls = message.get("tool_calls")
    if isinstance(tool_calls, list) and tool_calls:
        response["message"]["tool_calls"] = tool_calls

    usage = payload.get("usage")
    if isinstance(usage, dict):
        response["prompt_eval_count"] = int(usage.get("prompt_tokens", 0) or 0)
        response["eval_count"] = int(usage.get("completion_tokens", 0) or 0)
        response["total_tokens"] = int(usage.get("total_tokens", 0) or 0)
    return response


class Handler(BaseHTTPRequestHandler):
    server_version = "trtllm-adapter/0.2"
    protocol_version = "HTTP/1.1"

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

    def _native_unavailable(self) -> None:
        self._send_json(CONTROLLER.request_status_code(), CONTROLLER.health_payload())

    def _send_stream_headers(self, status: int, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def _stream_bytes(self, chunks: list[bytes] | tuple[bytes, ...]) -> None:
        for chunk in chunks:
            if not chunk:
                continue
            self.wfile.write(chunk)
            self.wfile.flush()

    def _stream_openai_mock_chat_completion(self, model: str, payload: dict) -> None:
        body_chunks = [b'data: {"choices":[{"delta":{"role":"assistant"},"index":0,"finish_reason":null}],"created":0,"id":"chatcmpl-mock","model":"']
        body_chunks.append(model.encode("utf-8"))
        body_chunks.append(b'","object":"chat.completion.chunk"}\n\n')
        tool_call = synthetic_tool_call_payload(payload)
        if tool_call is not None:
            tool_payload = {
                "id": "chatcmpl-mock",
                "object": "chat.completion.chunk",
                "created": int(time.time()),
                "model": model,
                "choices": [{"index": 0, "delta": {"tool_calls": [tool_call]}, "finish_reason": None}],
            }
            body_chunks.append(f"data: {json.dumps(tool_payload, separators=(',', ':'))}\n\n".encode("utf-8"))
            finish_reason = "tool_calls"
        else:
            content_payload = {
                "id": "chatcmpl-mock",
                "object": "chat.completion.chunk",
                "created": int(time.time()),
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "delta": {"content": f"trtllm synthetic response model={model}"},
                        "finish_reason": None,
                    }
                ],
            }
            body_chunks.append(f"data: {json.dumps(content_payload, separators=(',', ':'))}\n\n".encode("utf-8"))
            finish_reason = "stop"
        final_payload = {
            "id": "chatcmpl-mock",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": model,
            "choices": [{"index": 0, "delta": {}, "finish_reason": finish_reason}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }
        body_chunks.append(f"data: {json.dumps(final_payload, separators=(',', ':'))}\n\n".encode("utf-8"))
        body_chunks.append(b"data: [DONE]\n\n")
        self._send_stream_headers(HTTPStatus.OK, "text/event-stream; charset=utf-8")
        self._stream_bytes(body_chunks)

    def _stream_ollama_mock_chat(self, model: str, payload: dict) -> None:
        body_chunks: list[bytes] = []
        tool_call = synthetic_tool_call_payload(payload)
        if tool_call is not None:
            body_chunks.append(
                (
                    json.dumps(
                        {
                            "model": model,
                            "message": {"role": "assistant", "content": "", "tool_calls": [tool_call]},
                            "done": False,
                        },
                        separators=(",", ":"),
                    )
                    + "\n"
                ).encode("utf-8")
            )
            finish_reason = "tool_calls"
        else:
            body_chunks.append(
                (
                    json.dumps(
                        {
                            "model": model,
                            "message": {"role": "assistant", "content": f"trtllm synthetic response model={model}"},
                            "done": False,
                        },
                        separators=(",", ":"),
                    )
                    + "\n"
                ).encode("utf-8")
            )
            finish_reason = "stop"
        body_chunks.append(
            (
                json.dumps(
                    {
                        "model": model,
                        "message": {"role": "assistant", "content": ""},
                        "done": True,
                        "done_reason": finish_reason,
                        "prompt_eval_count": 0,
                        "eval_count": 0,
                        "total_tokens": 0,
                    },
                    separators=(",", ":"),
                )
                + "\n"
            ).encode("utf-8")
        )
        self._send_stream_headers(HTTPStatus.OK, "application/x-ndjson; charset=utf-8")
        self._stream_bytes(body_chunks)

    def _open_native_stream(self, method: str, path: str, payload: dict) -> tuple[http.client.HTTPConnection, http.client.HTTPResponse]:
        body = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        conn = http.client.HTTPConnection(CONTROLLER.native_host, CONTROLLER.native_port, timeout=30)
        conn.request(
            method,
            path,
            body=body,
            headers={
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
            },
        )
        response = conn.getresponse()
        if conn.sock is not None:
            conn.sock.settimeout(None)
        return conn, response

    def _stream_openai_event_line(self, requested_model: str, raw_line: bytes) -> bytes:
        if not raw_line.startswith(b"data: "):
            return raw_line
        payload = raw_line[6:].strip()
        if payload == b"[DONE]" or not payload:
            return raw_line
        try:
            parsed = json.loads(payload.decode("utf-8"))
        except Exception:
            return raw_line
        if isinstance(parsed, dict):
            parsed["model"] = requested_model
            return f"data: {json.dumps(parsed, separators=(',', ':'))}\n".encode("utf-8")
        return raw_line

    def _ollama_chunk_from_openai_event(self, requested_model: str, raw_line: bytes) -> list[bytes]:
        if not raw_line.startswith(b"data: "):
            return []
        payload = raw_line[6:].strip()
        if payload == b"[DONE]" or not payload:
            return []
        try:
            parsed = json.loads(payload.decode("utf-8"))
        except Exception:
            return []
        if not isinstance(parsed, dict):
            return []
        choices = parsed.get("choices")
        if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
            return []
        choice = choices[0]
        delta = choice.get("delta")
        if not isinstance(delta, dict):
            delta = {}
        chunks: list[bytes] = []
        content = delta.get("content")
        if isinstance(content, str) and content:
            chunks.append(
                (
                    json.dumps(
                        {
                            "model": requested_model,
                            "message": {"role": "assistant", "content": content},
                            "done": False,
                        },
                        separators=(",", ":"),
                    )
                    + "\n"
                ).encode("utf-8")
            )
        tool_calls = delta.get("tool_calls")
        if isinstance(tool_calls, list) and tool_calls:
            chunks.append(
                (
                    json.dumps(
                        {
                            "model": requested_model,
                            "message": {"role": "assistant", "content": "", "tool_calls": tool_calls},
                            "done": False,
                        },
                        separators=(",", ":"),
                    )
                    + "\n"
                ).encode("utf-8")
            )
        finish_reason = choice.get("finish_reason")
        if isinstance(finish_reason, str):
            usage = parsed.get("usage")
            final_payload = {
                "model": requested_model,
                "message": {"role": "assistant", "content": ""},
                "done": True,
                "done_reason": finish_reason,
            }
            if isinstance(usage, dict):
                final_payload["prompt_eval_count"] = int(usage.get("prompt_tokens", 0) or 0)
                final_payload["eval_count"] = int(usage.get("completion_tokens", 0) or 0)
                final_payload["total_tokens"] = int(usage.get("total_tokens", 0) or 0)
            chunks.append((json.dumps(final_payload, separators=(",", ":")) + "\n").encode("utf-8"))
        return chunks

    def _handle_native_chat_completion_stream(self, payload: dict, ollama_style: bool) -> None:
        if CONTROLLER.request_status_code() != HTTPStatus.OK:
            self._native_unavailable()
            return

        try:
            requested_model, serve_model = CONTROLLER.resolve_request_model(payload.get("model"))
        except ValueError as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": {"message": str(exc), "type": "invalid_request"}})
            return

        upstream_payload = {
            "model": serve_model,
            "messages": payload.get("messages") if isinstance(payload.get("messages"), list) else [],
            "stream": True,
        }
        if isinstance(payload.get("tools"), list):
            upstream_payload["tools"] = payload["tools"]
        if isinstance(payload.get("tool_choice"), (str, dict)):
            upstream_payload["tool_choice"] = payload["tool_choice"]

        conn: http.client.HTTPConnection | None = None
        response: http.client.HTTPResponse | None = None
        try:
            conn, response = self._open_native_stream("POST", "/v1/chat/completions", upstream_payload)
            if response.status >= 400:
                raw = response.read().decode("utf-8", errors="replace")
                try:
                    parsed = json.loads(raw) if raw else None
                except json.JSONDecodeError:
                    parsed = None
                if parsed is None:
                    self._send_json(response.status, {"error": {"message": raw or "empty upstream response", "type": "upstream_error"}})
                else:
                    self._send_json(response.status, parsed)
                return

            content_type = "application/x-ndjson; charset=utf-8" if ollama_style else "text/event-stream; charset=utf-8"
            self._send_stream_headers(response.status, content_type)
            while True:
                line = response.readline()
                if not line:
                    break
                if ollama_style:
                    for chunk in self._ollama_chunk_from_openai_event(requested_model, line):
                        self.wfile.write(chunk)
                        self.wfile.flush()
                    continue
                rewritten = self._stream_openai_event_line(requested_model, line)
                self.wfile.write(rewritten)
                self.wfile.flush()
        except ConnectionError as exc:
            CONTROLLER.native_error = str(exc)
            CONTROLLER.write_runtime_state()
            self._native_unavailable()
            return
        except Exception as exc:
            CONTROLLER.native_error = str(exc)
            CONTROLLER.write_runtime_state()
            if not self.wfile.closed:
                self._native_unavailable()
            return
        finally:
            if response is not None:
                response.close()
            if conn is not None:
                conn.close()

    def _handle_native_chat_completion(self, payload: dict, ollama_style: bool) -> None:
        if CONTROLLER.request_status_code() != HTTPStatus.OK:
            self._native_unavailable()
            return

        try:
            requested_model, serve_model = CONTROLLER.resolve_request_model(payload.get("model"))
        except ValueError as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": {"message": str(exc), "type": "invalid_request"}})
            return
        upstream_payload = {
            "model": serve_model,
            "messages": payload.get("messages") if isinstance(payload.get("messages"), list) else [],
            "stream": False,
        }
        if isinstance(payload.get("tools"), list):
            upstream_payload["tools"] = payload["tools"]
        if isinstance(payload.get("tool_choice"), (str, dict)):
            upstream_payload["tool_choice"] = payload["tool_choice"]

        try:
            status, upstream_json, upstream_text = CONTROLLER.native_request("POST", "/v1/chat/completions", payload=upstream_payload)
        except ConnectionError as exc:
            CONTROLLER.native_error = str(exc)
            CONTROLLER.write_runtime_state()
            self._native_unavailable()
            return

        if upstream_json is None:
            self._send_json(status, {"error": {"message": upstream_text or "empty upstream response", "type": "upstream_error"}})
            return
        if status >= 400:
            self._send_json(status, upstream_json)
            return

        upstream_json["model"] = requested_model
        if ollama_style:
            try:
                self._send_json(status, openai_to_ollama_payload(requested_model, upstream_json))
            except ValueError as exc:
                self._send_json(HTTPStatus.BAD_GATEWAY, {"error": {"message": str(exc), "type": "upstream_invalid_payload"}})
            return
        self._send_json(status, upstream_json)

    def _handle_native_embeddings(self, payload: dict) -> None:
        if CONTROLLER.request_status_code() != HTTPStatus.OK:
            self._native_unavailable()
            return

        prompt = payload.get("prompt")
        if not isinstance(prompt, str) or not prompt:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": {"message": "prompt must be a non-empty string", "type": "invalid_request"}})
            return

        try:
            requested_model, serve_model = CONTROLLER.resolve_request_model(payload.get("model"))
        except ValueError as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": {"message": str(exc), "type": "invalid_request"}})
            return

        try:
            status, upstream_json, upstream_text = CONTROLLER.native_request(
                "POST", "/v1/embeddings", payload={"model": serve_model, "input": prompt}
            )
        except ConnectionError as exc:
            CONTROLLER.native_error = str(exc)
            CONTROLLER.write_runtime_state()
            self._native_unavailable()
            return

        if upstream_json is None:
            self._send_json(status, {"error": {"message": upstream_text or "empty upstream response", "type": "upstream_error"}})
            return
        if status >= 400:
            self._send_json(status, upstream_json)
            return

        data = upstream_json.get("data")
        if not isinstance(data, list) or not data or not isinstance(data[0], dict) or not isinstance(data[0].get("embedding"), list):
            self._send_json(HTTPStatus.BAD_GATEWAY, {"error": {"message": "upstream embeddings payload missing vector", "type": "upstream_invalid_payload"}})
            return

        response = {"model": requested_model, "embedding": data[0]["embedding"]}
        usage = upstream_json.get("usage")
        if isinstance(usage, dict):
            response["usage"] = usage
        self._send_json(status, response)

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._send_json(CONTROLLER.status_code(), CONTROLLER.health_payload())
            return
        if self.path == "/api/tags":
            if CONTROLLER.status_code() != HTTPStatus.OK:
                self._native_unavailable()
                return
            self._send_json(HTTPStatus.OK, CONTROLLER.tags_payload())
            return
        if self.path == "/v1/models":
            if CONTROLLER.status_code() != HTTPStatus.OK:
                self._native_unavailable()
                return
            self._send_json(HTTPStatus.OK, CONTROLLER.models_payload())
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_POST(self) -> None:
        try:
            payload = self._read_json()
        except Exception as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": {"message": str(exc), "type": "invalid_request"}})
            return

        if self.path == "/api/chat":
            model = payload.get("model")
            if not isinstance(model, str) or not model:
                model = CONTROLLER.primary_entry.display_name
                payload["model"] = model
            if CONTROLLER.runtime_mode_effective == "mock":
                if bool(payload.get("stream")):
                    self._stream_ollama_mock_chat(model, payload)
                    return
                self._send_json(HTTPStatus.OK, mock_api_chat_payload(model, payload))
                return
            if bool(payload.get("stream")):
                self._handle_native_chat_completion_stream(payload, ollama_style=True)
                return
            self._handle_native_chat_completion(payload, ollama_style=True)
            return

        if self.path == "/v1/chat/completions":
            model = payload.get("model")
            if not isinstance(model, str) or not model:
                payload["model"] = CONTROLLER.primary_entry.display_name
            if CONTROLLER.runtime_mode_effective == "mock":
                if bool(payload.get("stream")):
                    self._stream_openai_mock_chat_completion(payload["model"], payload)
                    return
                self._send_json(HTTPStatus.OK, mock_chat_completion_payload(payload["model"], payload))
                return
            if bool(payload.get("stream")):
                self._handle_native_chat_completion_stream(payload, ollama_style=False)
                return
            self._handle_native_chat_completion(payload, ollama_style=False)
            return

        if self.path == "/api/embeddings":
            model = payload.get("model")
            if not isinstance(model, str) or not model:
                payload["model"] = CONTROLLER.primary_entry.display_name
            if CONTROLLER.runtime_mode_effective == "mock":
                prompt = payload.get("prompt")
                if not isinstance(prompt, str) or not prompt:
                    self._send_json(HTTPStatus.BAD_REQUEST, {"error": {"message": "prompt must be a non-empty string", "type": "invalid_request"}})
                    return
                vector = deterministic_embedding_vector(f"{payload['model']}:{prompt}")
                self._send_json(HTTPStatus.OK, {"model": payload["model"], "embedding": vector})
                return
            self._handle_native_embeddings(payload)
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def log_message(self, fmt: str, *args: object) -> None:
        return


def handle_shutdown(_signum: int, _frame: object) -> None:
    CONTROLLER.stop()
    raise SystemExit(0)


def main() -> None:
    CONTROLLER.start()
    atexit.register(CONTROLLER.stop)
    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)
    server = ThreadingHTTPServer((CONTROLLER.listen_host, CONTROLLER.listen_port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
