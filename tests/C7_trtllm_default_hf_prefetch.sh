#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

helper_script="${REPO_ROOT}/deployments/trtllm/prefetch_default_model.sh"
init_script="${REPO_ROOT}/deployments/core/init_runtime.sh"
routes_template="${REPO_ROOT}/examples/core/model_routes.yml"
[[ -x "${helper_script}" ]] || fail "TRT HF prefetch helper missing: ${helper_script}"
[[ -f "${init_script}" ]] || fail "core init script missing: ${init_script}"
[[ -f "${routes_template}" ]] || fail "core model routes template missing: ${routes_template}"

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

runtime_root="${tmp_root}/runtime"
fixture_source="${tmp_root}/fixture-nano-fp8"
mkdir -p "${runtime_root}/secrets/runtime" "${runtime_root}/trtllm/models" "${runtime_root}/trtllm/state" "${runtime_root}/trtllm/logs" "${fixture_source}"

printf 'hf_test_token\n' > "${runtime_root}/secrets/runtime/huggingface.token"
cat > "${fixture_source}/config.json" <<'JSON'
{"model_type":"nemotron_h"}
JSON
cat > "${fixture_source}/generation_config.json" <<'JSON'
{"temperature":0.7}
JSON

AGENTIC_PROFILE=rootless-dev \
AGENTIC_ROOT="${runtime_root}" \
COMPOSE_PROFILES=trt \
TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" \
TRTLLM_HF_PREFETCH_SOURCE_DIR="${fixture_source}" \
TRTLLM_HF_PREFETCH_REVISION="fixture-rev" \
bash "${helper_script}" \
  || fail "default TRT HF prefetch helper failed for Nano FP8"

nano_cache_root="${runtime_root}/trtllm/models/huggingface/hub/models--nvidia--NVIDIA-Nemotron-3-Nano-30B-A3B-FP8"
[[ -f "${nano_cache_root}/refs/main" ]] || fail "Nano prefetch must write hub refs/main"
grep -q '^fixture-rev$' "${nano_cache_root}/refs/main" \
  || fail "Nano prefetch must pin refs/main to the requested revision"
[[ -f "${nano_cache_root}/snapshots/fixture-rev/config.json" ]] \
  || fail "Nano prefetch must materialize config.json under the snapshot directory"
[[ -f "${nano_cache_root}/snapshots/fixture-rev/generation_config.json" ]] \
  || fail "Nano prefetch must materialize generation_config.json under the snapshot directory"
[[ ! -e "${runtime_root}/trtllm/models/cascade_30b_nvfp4" ]] \
  || fail "default Nano prefetch must not create the local Cascade payload"
[[ ! -e "${runtime_root}/trtllm/models/super_fp4" ]] \
  || fail "default Nano prefetch must not create the local Super payload"
ok "default TRT HF prefetch materializes only the Nano FP8 cache"

skip_root="${tmp_root}/skip-runtime"
mkdir -p "${skip_root}/secrets/runtime" "${skip_root}/trtllm/models" "${skip_root}/trtllm/state" "${skip_root}/trtllm/logs"
printf 'hf_test_token\n' > "${skip_root}/secrets/runtime/huggingface.token"

skip_output="$(
  AGENTIC_PROFILE=rootless-dev \
  AGENTIC_ROOT="${skip_root}" \
  COMPOSE_PROFILES=trt \
  TRTLLM_MODELS="https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4" \
  TRTLLM_HF_PREFETCH_SOURCE_DIR="${fixture_source}" \
  TRTLLM_HF_PREFETCH_REVISION="fixture-rev" \
  bash "${helper_script}"
)"
printf '%s\n' "${skip_output}" | grep -q 'skip TRT HF prefetch' \
  || fail "helper must skip non-default TRT aliases"
[[ ! -e "${skip_root}/trtllm/models/huggingface/hub/models--nvidia--NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" ]] \
  || fail "non-default TRT aliases must not create the Nano cache"
ok "TRT HF prefetch skips non-default aliases such as Cascade NVFP4"

grep -q 'prefetch_trtllm_default_model' "${init_script}" \
  || fail "core init runtime must call the TRT HF prefetch helper"
grep -q 'ensure_gate_default_trtllm_route' "${init_script}" \
  || fail "core init runtime must normalize the gate route for the default TRT model"
if grep -q 'prepare_trtllm_nvfp4_model' "${init_script}"; then
  fail "core init runtime must not auto-bootstrap Cascade or Super NVFP4 payloads"
fi
ok "core init runtime wires only the Nano HF prefetch helper on the default TRT path"

grep -q 'name: default-trtllm-model' "${routes_template}" \
  || fail "core model routes template must expose a dedicated default TRT route"
grep -q 'https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8' "${routes_template}" \
  || fail "core model routes template must route the default Nano FP8 URL to trtllm"
grep -q 'nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8' "${routes_template}" \
  || fail "core model routes template must route the default Nano FP8 handle to trtllm"
ok "core model routes template pins the default Nano FP8 alias to trtllm"

ok "C7_trtllm_default_hf_prefetch passed"
