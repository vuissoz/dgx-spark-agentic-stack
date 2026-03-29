#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

server_path="${SCRIPT_DIR}/../deployments/trtllm/server.py"
strict_model_dir="${tmp_root}/super_fp4"
cascade_model_dir="${tmp_root}/cascade_30b_nvfp4"
state_dir="${tmp_root}/state"
logs_dir="${tmp_root}/logs"
models_dir="${tmp_root}/models"
mkdir -p "${strict_model_dir}" "${cascade_model_dir}" "${state_dir}" "${logs_dir}" "${models_dir}"

TRTLLM_RUNTIME_MODE=mock \
TRTLLM_NATIVE_MODEL_POLICY=strict-nvfp4-local-only \
TRTLLM_NVFP4_LOCAL_MODEL_DIR="${strict_model_dir}" \
TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4" \
TRTLLM_MODELS_DIR="${models_dir}" \
TRTLLM_STATE_DIR="${state_dir}" \
TRTLLM_LOGS_DIR="${logs_dir}" \
TRTLLM_NATIVE_START_TIMEOUT_SECONDS=5 \
python3 - "${server_path}" "${strict_model_dir}" <<'PY' || fail "strict NVFP4 local-only alias mapping is invalid"
import importlib.util
import pathlib
import sys

server_path = pathlib.Path(sys.argv[1])
strict_model_dir = sys.argv[2]
spec = importlib.util.spec_from_file_location("trtllm_server_strict", server_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
controller = module.CONTROLLER

assert controller.native_model_policy == "strict-nvfp4-local-only"
assert controller.runtime_mode_effective == "mock"
assert controller.primary_entry.display_name == module.DEFAULT_TRTLLM_MODEL
assert controller.primary_entry.requested_handle == module.DEFAULT_TRTLLM_MODEL_HANDLE
assert controller.primary_entry.serve_handle == strict_model_dir
assert strict_model_dir in controller.primary_entry.aliases
payload = controller.health_payload()
assert payload["native_model_policy"] == "strict-nvfp4-local-only"
assert payload["primary_model_handle"] == strict_model_dir
assert payload["nvfp4_local_model_dir"] == strict_model_dir
PY
ok "strict NVFP4 local-only maps the Nemotron alias to a local directory"

TRTLLM_RUNTIME_MODE=mock \
TRTLLM_NATIVE_MODEL_POLICY=strict-nvfp4-local-only \
TRTLLM_NVFP4_LOCAL_MODEL_DIR="${cascade_model_dir}" \
TRTLLM_NVFP4_HF_REPO="chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4" \
TRTLLM_MODELS="https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4" \
TRTLLM_MODELS_DIR="${models_dir}" \
TRTLLM_STATE_DIR="${state_dir}" \
TRTLLM_LOGS_DIR="${logs_dir}" \
TRTLLM_NATIVE_START_TIMEOUT_SECONDS=5 \
python3 - "${server_path}" "${cascade_model_dir}" <<'PY' || fail "strict NVFP4 local-only alias mapping must also work for Cascade 30B"
import importlib.util
import pathlib
import sys

server_path = pathlib.Path(sys.argv[1])
cascade_model_dir = sys.argv[2]
spec = importlib.util.spec_from_file_location("trtllm_server_strict_cascade", server_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
controller = module.CONTROLLER

assert controller.native_model_policy == "strict-nvfp4-local-only"
assert controller.primary_entry.display_name == "https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4"
assert controller.primary_entry.requested_handle == "chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4"
assert controller.primary_entry.serve_handle == cascade_model_dir
PY
ok "strict NVFP4 local-only maps the Cascade 30B alias to a local directory"

TRTLLM_RUNTIME_MODE=auto \
TRTLLM_NATIVE_MODEL_POLICY=strict-nvfp4-local-only \
TRTLLM_NVFP4_LOCAL_MODEL_DIR="${tmp_root}/missing-super_fp4" \
TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4" \
TRTLLM_MODELS_DIR="${models_dir}" \
TRTLLM_STATE_DIR="${state_dir}" \
TRTLLM_LOGS_DIR="${logs_dir}" \
TRTLLM_NATIVE_START_TIMEOUT_SECONDS=5 \
python3 - "${server_path}" <<'PY' || fail "strict NVFP4 local-only must fail closed when the local directory is absent"
import importlib.util
import pathlib
import sys

server_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("trtllm_server_strict_auto", server_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
controller = module.CONTROLLER

assert controller.runtime_mode_effective == "native"
assert controller.primary_entry.serve_handle.endswith("/missing-super_fp4")
PY
ok "strict NVFP4 local-only disables silent auto->mock fallback"

TRTLLM_RUNTIME_MODE=mock \
TRTLLM_NATIVE_MODEL_POLICY=strict-nvfp4-local-only \
TRTLLM_NVFP4_LOCAL_MODEL_DIR="${strict_model_dir}" \
TRTLLM_MODELS="nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-FP8" \
TRTLLM_MODELS_DIR="${models_dir}" \
TRTLLM_STATE_DIR="${state_dir}" \
TRTLLM_LOGS_DIR="${logs_dir}" \
TRTLLM_NATIVE_START_TIMEOUT_SECONDS=5 \
python3 - "${server_path}" <<'PY' || fail "strict NVFP4 local-only must reject non-NVFP4 model exposure"
import importlib.util
import pathlib
import sys

server_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("trtllm_server_strict_invalid", server_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
controller = module.CONTROLLER

assert "strict NVFP4 local-only mode requires TRTLLM_MODELS" in controller.configuration_error
payload = controller.health_payload()
assert payload["status"] == "error"
assert "strict NVFP4 local-only mode requires TRTLLM_MODELS" in payload["error"]
PY
ok "strict NVFP4 local-only rejects FP8 exposure configuration"

TRTLLM_RUNTIME_MODE=mock \
TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" \
TRTLLM_MODELS_DIR="${models_dir}" \
TRTLLM_STATE_DIR="${state_dir}" \
TRTLLM_LOGS_DIR="${logs_dir}" \
TRTLLM_NATIVE_MAX_BATCH_SIZE=1 \
TRTLLM_NATIVE_MAX_NUM_TOKENS=4096 \
TRTLLM_NATIVE_MAX_SEQ_LEN=32768 \
TRTLLM_NATIVE_ENABLE_CUDA_GRAPH=false \
TRTLLM_NATIVE_CUDA_GRAPH_MAX_BATCH_SIZE=1 \
TRTLLM_NATIVE_CUDA_GRAPH_ENABLE_PADDING=false \
TRTLLM_NATIVE_START_TIMEOUT_SECONDS=5 \
python3 - "${server_path}" <<'PY' || fail "Nano runtime defaults must bound warmup and disable CUDA graph by default"
import importlib.util
import pathlib
import sys

server_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("trtllm_server_nano_defaults", server_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
controller = module.CONTROLLER

cfg = controller.render_extra_config()
cmd = controller.build_native_command()
env = controller.build_native_env("hf_test_token")
models_payload = controller.models_payload()
tags_payload = controller.tags_payload()
model_ids = [item["id"] for item in models_payload["data"]]
tag_names = [item["name"] for item in tags_payload["models"]]
friendly_alias = module.friendly_catalog_alias(
    controller.primary_entry.display_name,
    controller.primary_entry.requested_handle,
    controller.primary_entry.serve_handle,
)

assert controller.native_max_num_tokens == 4096
assert controller.native_max_seq_len == 32768
assert controller.native_enable_cuda_graph is False
assert friendly_alias == "trtllm/nvidia-nemotron-3-nano-30b-a3b-fp8"
assert friendly_alias in controller.primary_entry.aliases
assert "https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" in model_ids
assert friendly_alias in model_ids
assert friendly_alias in tag_names
assert "cuda_graph_config:" not in cfg
assert "max_num_tokens: 4096" in cfg
assert "--max_num_tokens" in cmd and "4096" in cmd
assert "--max_seq_len" in cmd and "32768" in cmd
assert env["TMPDIR"].endswith("/state/cache/tmp")
assert env["TRITON_CACHE_DIR"].endswith("/state/cache/triton")
assert env["TORCHINDUCTOR_CACHE_DIR"].endswith("/state/cache/torchinductor")
assert env["TORCH_EXTENSIONS_DIR"].endswith("/state/cache/torch_extensions")
assert env["HF_TOKEN"] == "hf_test_token"
PY
ok "Nano runtime defaults bound seq len, expose a friendly TRT alias, avoid CUDA graph warmup, and redirect JIT caches under /state/cache"

TRTLLM_RUNTIME_MODE=mock \
TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" \
TRTLLM_MODELS_DIR="${models_dir}" \
TRTLLM_STATE_DIR="${state_dir}" \
TRTLLM_LOGS_DIR="${logs_dir}" \
TRTLLM_NATIVE_MAX_BATCH_SIZE=1 \
TRTLLM_NATIVE_MAX_NUM_TOKENS=2048 \
TRTLLM_NATIVE_MAX_SEQ_LEN=8192 \
TRTLLM_NATIVE_ENABLE_CUDA_GRAPH=true \
TRTLLM_NATIVE_CUDA_GRAPH_MAX_BATCH_SIZE=4 \
TRTLLM_NATIVE_CUDA_GRAPH_ENABLE_PADDING=true \
TRTLLM_NATIVE_START_TIMEOUT_SECONDS=5 \
python3 - "${server_path}" <<'PY' || fail "CUDA graph config must remain available when explicitly enabled"
import importlib.util
import pathlib
import sys

server_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("trtllm_server_nano_cuda_graph", server_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
controller = module.CONTROLLER

cfg = controller.render_extra_config()

assert controller.native_enable_cuda_graph is True
assert "cuda_graph_config:" in cfg
assert "max_batch_size: 4" in cfg
assert "enable_padding: true" in cfg
assert "max_num_tokens: 2048" in cfg
PY
ok "CUDA graph config can still be enabled explicitly for TRT native runtime"

ok "C4_trtllm_strict_nvfp4_local_only passed"
