#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

runtime_lib="${REPO_ROOT}/scripts/lib/runtime.sh"
bootstrap_script="${REPO_ROOT}/deployments/trtllm/prepare_nvfp4_model.sh"

[[ -f "${runtime_lib}" ]] || fail "runtime lib missing: ${runtime_lib}"
[[ -f "${bootstrap_script}" ]] || fail "bootstrap script missing: ${bootstrap_script}"

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

runtime_root="${tmp_root}/runtime"
fixture_source="${tmp_root}/fixture-super-fp4"
mkdir -p \
  "${runtime_root}/secrets/runtime" \
  "${runtime_root}/trtllm/models" \
  "${runtime_root}/trtllm/state" \
  "${runtime_root}/trtllm/logs" \
  "${fixture_source}"

printf 'hf_test_token\n' > "${runtime_root}/secrets/runtime/huggingface.token"

cat > "${fixture_source}/config.json" <<'JSON'
{"model_type":"nemotron_h"}
JSON
cat > "${fixture_source}/model.safetensors.index.json" <<'JSON'
{"metadata":{"total_size":123},"weight_map":{"lm_head.weight":"model-00001-of-00001.safetensors"}}
JSON
printf 'fixture-weight\n' > "${fixture_source}/model-00001-of-00001.safetensors"

runtime_dump="$(
  AGENTIC_PROFILE=rootless-dev \
  AGENTIC_ROOT="${runtime_root}" \
  COMPOSE_PROFILES=trt \
  TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4" \
  bash -lc "source '${runtime_lib}'; printf 'policy=%s\nlocal_dir=%s\nrepo=%s\nrevision=%s\n' \"\${TRTLLM_NATIVE_MODEL_POLICY}\" \"\${TRTLLM_NVFP4_LOCAL_MODEL_DIR}\" \"\${TRTLLM_NVFP4_HF_REPO}\" \"\${TRTLLM_NVFP4_HF_REVISION}\""
)"

printf '%s\n' "${runtime_dump}" | grep -q '^policy=strict-nvfp4-local-only$' \
  || fail "runtime defaults must auto-enable strict NVFP4 local-only when TRT + token are present"
printf '%s\n' "${runtime_dump}" | grep -q '^local_dir=/models/super_fp4$' \
  || fail "runtime defaults must keep /models/super_fp4 as local NVFP4 target"
printf '%s\n' "${runtime_dump}" | grep -q '^repo=nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4$' \
  || fail "runtime defaults must expose the pinned NVFP4 repo"
printf '%s\n' "${runtime_dump}" | grep -q '^revision=b1ffe4992d7db6d768453a551a656b8d12c638fb$' \
  || fail "runtime defaults must expose the pinned NVFP4 revision"
ok "runtime defaults auto-select strict NVFP4 local-only for the default TRT model"

AGENTIC_PROFILE=rootless-dev \
AGENTIC_ROOT="${runtime_root}" \
COMPOSE_PROFILES=trt \
TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4" \
TRTLLM_NVFP4_PREPARE_SOURCE_DIR="${fixture_source}" \
bash "${bootstrap_script}" \
  || fail "NVFP4 bootstrap script failed on local fixture source"

target_dir="${runtime_root}/trtllm/models/super_fp4"
[[ -f "${target_dir}/config.json" ]] || fail "NVFP4 bootstrap did not populate config.json"
[[ -f "${target_dir}/model.safetensors.index.json" ]] || fail "NVFP4 bootstrap did not populate model.safetensors.index.json"
[[ -f "${target_dir}/model-00001-of-00001.safetensors" ]] || fail "NVFP4 bootstrap did not populate referenced safetensor shard"
ok "NVFP4 bootstrap populates the local super_fp4 directory"

rm -rf "${fixture_source}"
AGENTIC_PROFILE=rootless-dev \
AGENTIC_ROOT="${runtime_root}" \
COMPOSE_PROFILES=trt \
TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4" \
bash "${bootstrap_script}" \
  || fail "NVFP4 bootstrap must be idempotent once the payload is already complete"
ok "NVFP4 bootstrap is idempotent after the model payload is complete"

ok "C5_trtllm_nvfp4_bootstrap passed"
