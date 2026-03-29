#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

runtime_lib="${REPO_ROOT}/scripts/lib/runtime.sh"
bootstrap_script="${REPO_ROOT}/deployments/trtllm/prepare_nvfp4_model.sh"
compose_file="${REPO_ROOT}/compose/compose.core.yml"

[[ -f "${runtime_lib}" ]] || fail "runtime lib missing: ${runtime_lib}"
[[ -f "${bootstrap_script}" ]] || fail "bootstrap script missing: ${bootstrap_script}"
[[ -f "${compose_file}" ]] || fail "compose file missing: ${compose_file}"

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

runtime_root="${tmp_root}/runtime"
fixture_source="${tmp_root}/fixture-super-fp4"
fixture_cascade_source="${tmp_root}/fixture-cascade-fp4"
mkdir -p \
  "${runtime_root}/secrets/runtime" \
  "${runtime_root}/trtllm/models" \
  "${runtime_root}/trtllm/state" \
  "${runtime_root}/trtllm/logs" \
  "${fixture_source}" \
  "${fixture_cascade_source}"

printf 'hf_test_token\n' > "${runtime_root}/secrets/runtime/huggingface.token"

cat > "${fixture_source}/config.json" <<'JSON'
{"model_type":"nemotron_h"}
JSON
cat > "${fixture_source}/model.safetensors.index.json" <<'JSON'
{"metadata":{"total_size":123},"weight_map":{"lm_head.weight":"model-00001-of-00001.safetensors"}}
JSON
printf 'fixture-weight\n' > "${fixture_source}/model-00001-of-00001.safetensors"
cat > "${fixture_cascade_source}/config.json" <<'JSON'
{"model_type":"nemotron_h"}
JSON
cat > "${fixture_cascade_source}/model.safetensors.index.json" <<'JSON'
{"metadata":{"total_size":456},"weight_map":{"lm_head.weight":"model-00001-of-00001.safetensors"}}
JSON
printf 'fixture-cascade-weight\n' > "${fixture_cascade_source}/model-00001-of-00001.safetensors"

runtime_dump="$(
  AGENTIC_PROFILE=rootless-dev \
  AGENTIC_ROOT="${runtime_root}" \
  COMPOSE_PROFILES=trt \
  TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" \
  bash -lc "source '${runtime_lib}'; printf 'policy=%s\nlocal_dir=%s\nrepo=%s\nrevision=%s\n' \"\${TRTLLM_NATIVE_MODEL_POLICY}\" \"\${TRTLLM_NVFP4_LOCAL_MODEL_DIR}\" \"\${TRTLLM_NVFP4_HF_REPO}\" \"\${TRTLLM_NVFP4_HF_REVISION}\""
)"

printf '%s\n' "${runtime_dump}" | grep -q '^policy=strict-nvfp4-local-only$' \
  || fail "runtime defaults must auto-promote to strict local-only when the configured TRT model matches the local payload contract"
printf '%s\n' "${runtime_dump}" | grep -q '^local_dir=/models/trtllm-model$' \
  || fail "runtime defaults must keep /models/trtllm-model as the local strict-mode target"
printf '%s\n' "${runtime_dump}" | grep -q '^repo=nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8$' \
  || fail "runtime defaults must derive the local TRT repo from TRTLLM_MODELS"
printf '%s\n' "${runtime_dump}" | grep -q '^revision=main$' \
  || fail "runtime defaults must keep the local TRT revision on main unless overridden"
ok "runtime defaults keep one configured TRT model and derive strict local metadata from it"

AGENTIC_PROFILE=rootless-dev \
AGENTIC_ROOT="${runtime_root}" \
COMPOSE_PROFILES=trt \
TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" \
TRTLLM_NVFP4_PREPARE_SOURCE_DIR="${fixture_source}" \
bash "${bootstrap_script}" \
  || fail "NVFP4 bootstrap script failed on local fixture source"

target_dir="${runtime_root}/trtllm/models/trtllm-model"
[[ -f "${target_dir}/config.json" ]] || fail "NVFP4 bootstrap did not populate config.json"
[[ -f "${target_dir}/model.safetensors.index.json" ]] || fail "NVFP4 bootstrap did not populate model.safetensors.index.json"
[[ -f "${target_dir}/model-00001-of-00001.safetensors" ]] || fail "NVFP4 bootstrap did not populate referenced safetensor shard"
ok "local TRT bootstrap populates the single configured payload directory"

override_runtime_dump="$(
  AGENTIC_PROFILE=rootless-dev \
  AGENTIC_ROOT="${runtime_root}" \
  COMPOSE_PROFILES=trt \
  TRTLLM_MODELS="https://huggingface.co/acme/Custom-TRT-Local-Model" \
  TRTLLM_NVFP4_LOCAL_MODEL_DIR="/models/custom-trt-model" \
  TRTLLM_NVFP4_HF_REVISION="test-rev" \
  bash -lc "source '${runtime_lib}'; printf 'local_dir=%s\nrepo=%s\nrevision=%s\n' \"\${TRTLLM_NVFP4_LOCAL_MODEL_DIR}\" \"\${TRTLLM_NVFP4_HF_REPO}\" \"\${TRTLLM_NVFP4_HF_REVISION}\""
)"

printf '%s\n' "${override_runtime_dump}" | grep -q '^local_dir=/models/custom-trt-model$' \
  || fail "runtime must keep an explicit local TRT directory override"
printf '%s\n' "${override_runtime_dump}" | grep -q '^repo=acme/Custom-TRT-Local-Model$' \
  || fail "runtime must derive the repo from an overridden TRTLLM_MODELS value"
printf '%s\n' "${override_runtime_dump}" | grep -q '^revision=test-rev$' \
  || fail "runtime must keep an explicit local TRT revision override"
ok "runtime keeps single-model local override values without catalog indirection"

AGENTIC_PROFILE=rootless-dev \
AGENTIC_ROOT="${runtime_root}" \
COMPOSE_PROFILES=trt \
TRTLLM_MODELS="https://huggingface.co/acme/Custom-TRT-Local-Model" \
TRTLLM_NVFP4_LOCAL_MODEL_DIR="/models/custom-trt-model" \
TRTLLM_NVFP4_HF_REPO="acme/Custom-TRT-Local-Model" \
TRTLLM_NVFP4_HF_REVISION="test-rev" \
TRTLLM_NVFP4_PREPARE_SOURCE_DIR="${fixture_cascade_source}" \
bash "${bootstrap_script}" \
  || fail "custom local TRT bootstrap script failed on local fixture source"

custom_target_dir="${runtime_root}/trtllm/models/custom-trt-model"
[[ -f "${custom_target_dir}/config.json" ]] || fail "custom bootstrap did not populate config.json"
[[ -f "${custom_target_dir}/model.safetensors.index.json" ]] || fail "custom bootstrap did not populate model.safetensors.index.json"
[[ -f "${custom_target_dir}/model-00001-of-00001.safetensors" ]] || fail "custom bootstrap did not populate referenced safetensor shard"
ok "local TRT bootstrap also populates an explicitly overridden target directory"

rm -rf "${fixture_source}"
rm -rf "${fixture_cascade_source}"
AGENTIC_PROFILE=rootless-dev \
AGENTIC_ROOT="${runtime_root}" \
COMPOSE_PROFILES=trt \
TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" \
bash "${bootstrap_script}" \
  || fail "NVFP4 bootstrap must be idempotent once the payload is already complete"
ok "local TRT bootstrap is idempotent after the model payload is complete"

compose_dump="$(docker compose --profile trt -f "${compose_file}" config 2>/dev/null)"
printf '%s\n' "${compose_dump}" | grep -q 'TRTLLM_MODELS: https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8' \
  || fail "compose config must expose Nano FP8 as the default TRTLLM_MODELS alias"
printf '%s\n' "${compose_dump}" | grep -q 'TRTLLM_NATIVE_MAX_NUM_TOKENS: "4096"' \
  || fail "compose config must bound TRTLLM_NATIVE_MAX_NUM_TOKENS for Nano startup safety"
printf '%s\n' "${compose_dump}" | grep -q 'TRTLLM_NATIVE_MAX_SEQ_LEN: "32768"' \
  || fail "compose config must bound TRTLLM_NATIVE_MAX_SEQ_LEN for Nano startup safety"
printf '%s\n' "${compose_dump}" | grep -q 'TRTLLM_NATIVE_ENABLE_CUDA_GRAPH: "false"' \
  || fail "compose config must disable CUDA graph by default for Nano startup safety"
printf '%s\n' "${compose_dump}" | grep -q 'TRTLLM_NVFP4_HF_REPO: nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8' \
  || fail "compose config must pass the single configured TRT repo into the trtllm container"
printf '%s\n' "${compose_dump}" | grep -q 'TRTLLM_NVFP4_HF_REVISION: main' \
  || fail "compose config must pass the local TRT revision into the trtllm container"
printf '%s\n' "${compose_dump}" | grep -q 'TRTLLM_NVFP4_LOCAL_MODEL_DIR: /models/trtllm-model' \
  || fail "compose config must pass the single local TRT model directory into the trtllm container"
ok "compose config exposes Nano FP8 by default with bounded startup settings and single-model local metadata"

ok "C5_trtllm_nvfp4_bootstrap passed"
