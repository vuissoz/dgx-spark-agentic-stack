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
state_dir="${tmp_root}/state"
logs_dir="${tmp_root}/logs"
models_dir="${tmp_root}/models"
mkdir -p "${strict_model_dir}" "${state_dir}" "${logs_dir}" "${models_dir}"

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

ok "C4_trtllm_strict_nvfp4_local_only passed"
