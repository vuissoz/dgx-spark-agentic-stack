#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

profile_output="$(
  COMPOSE_PROFILES='trt,optional-goose' \
  TRTLLM_MODELS='https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8' \
  TRTLLM_NATIVE_MODEL_POLICY='strict-nvfp4-local-only' \
  TRTLLM_NVFP4_LOCAL_MODEL_DIR='/models/trtllm-model' \
  TRTLLM_NVFP4_HF_REPO='nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8' \
  TRTLLM_NVFP4_HF_REVISION='main' \
  TRTLLM_NVFP4_PREPARE_ENABLED='true' \
  "${agent_bin}" profile
)"
printf '%s\n' "${profile_output}" | grep -q '^compose_profiles=trt,optional-goose$' \
  || fail "agent profile must print the effective compose_profiles value"
printf '%s\n' "${profile_output}" | grep -q '^trtllm_models=https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8$' \
  || fail "agent profile must print trtllm_models"
printf '%s\n' "${profile_output}" | grep -q '^trtllm_native_model_policy=strict-nvfp4-local-only$' \
  || fail "agent profile must print trtllm_native_model_policy"
printf '%s\n' "${profile_output}" | grep -q '^trtllm_nvfp4_local_model_dir=/models/trtllm-model$' \
  || fail "agent profile must print trtllm_nvfp4_local_model_dir"
printf '%s\n' "${profile_output}" | grep -q '^trtllm_nvfp4_hf_repo=nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8$' \
  || fail "agent profile must print trtllm_nvfp4_hf_repo"
printf '%s\n' "${profile_output}" | grep -q '^trtllm_nvfp4_hf_revision=main$' \
  || fail "agent profile must print trtllm_nvfp4_hf_revision"
printf '%s\n' "${profile_output}" | grep -q '^trtllm_nvfp4_prepare_enabled=true$' \
  || fail "agent profile must print trtllm_nvfp4_prepare_enabled"

empty_output="$(env -u COMPOSE_PROFILES "${agent_bin}" profile)"
printf '%s\n' "${empty_output}" | grep -q '^compose_profiles=$' \
  || fail "agent profile must print compose_profiles even when it is empty"

ok "00_profile_compose_profiles passed"
