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
  TRTLLM_MODELS="https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4" \
  bash -lc "source '${runtime_lib}'; printf 'active_key=%s\npolicy=%s\nlocal_dir=%s\nrepo=%s\nrevision=%s\n' \"\${TRTLLM_ACTIVE_MODEL_KEY}\" \"\${TRTLLM_NATIVE_MODEL_POLICY}\" \"\${TRTLLM_NVFP4_LOCAL_MODEL_DIR}\" \"\${TRTLLM_NVFP4_HF_REPO}\" \"\${TRTLLM_NVFP4_HF_REVISION}\""
)"

printf '%s\n' "${runtime_dump}" | grep -q '^active_key=nemotron-cascade-30b$' \
  || fail "runtime defaults must expose the default TRTLLM_ACTIVE_MODEL_KEY"
printf '%s\n' "${runtime_dump}" | grep -q '^policy=strict-nvfp4-local-only$' \
  || fail "runtime defaults must auto-enable strict NVFP4 local-only when TRT + token are present"
printf '%s\n' "${runtime_dump}" | grep -q '^local_dir=/models/cascade_30b_nvfp4$' \
  || fail "runtime defaults must keep /models/cascade_30b_nvfp4 as local NVFP4 target"
printf '%s\n' "${runtime_dump}" | grep -q '^repo=chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4$' \
  || fail "runtime defaults must expose the pinned NVFP4 repo"
printf '%s\n' "${runtime_dump}" | grep -q '^revision=80ee3ccfe8cb5eb019a0cde78449e8b197a0155f$' \
  || fail "runtime defaults must expose the pinned NVFP4 revision"
ok "runtime defaults auto-select strict NVFP4 local-only for the default Cascade TRT model"

AGENTIC_PROFILE=rootless-dev \
AGENTIC_ROOT="${runtime_root}" \
COMPOSE_PROFILES=trt \
TRTLLM_MODELS="https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4" \
TRTLLM_NVFP4_PREPARE_SOURCE_DIR="${fixture_source}" \
bash "${bootstrap_script}" \
  || fail "NVFP4 bootstrap script failed on local fixture source"

target_dir="${runtime_root}/trtllm/models/cascade_30b_nvfp4"
[[ -f "${target_dir}/config.json" ]] || fail "NVFP4 bootstrap did not populate config.json"
[[ -f "${target_dir}/model.safetensors.index.json" ]] || fail "NVFP4 bootstrap did not populate model.safetensors.index.json"
[[ -f "${target_dir}/model-00001-of-00001.safetensors" ]] || fail "NVFP4 bootstrap did not populate referenced safetensor shard"
ok "NVFP4 bootstrap populates the default local Cascade directory"

cascade_runtime_dump="$(
  AGENTIC_PROFILE=rootless-dev \
  AGENTIC_ROOT="${runtime_root}" \
  COMPOSE_PROFILES=trt \
  TRTLLM_ACTIVE_MODEL_KEY=nemotron-cascade-30b \
  TRTLLM_MODELS="https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4" \
  bash -lc "source '${runtime_lib}'; printf 'active_key=%s\nlocal_dir=%s\nrepo=%s\nrevision=%s\n' \"\${TRTLLM_ACTIVE_MODEL_KEY}\" \"\${TRTLLM_NVFP4_LOCAL_MODEL_DIR}\" \"\${TRTLLM_NVFP4_HF_REPO}\" \"\${TRTLLM_NVFP4_HF_REVISION}\""
)"

printf '%s\n' "${cascade_runtime_dump}" | grep -q '^active_key=nemotron-cascade-30b$' \
  || fail "runtime must keep the Cascade key when explicitly selected"
printf '%s\n' "${cascade_runtime_dump}" | grep -q '^local_dir=/models/cascade_30b_nvfp4$' \
  || fail "runtime must derive the Cascade local directory from the model catalog"
printf '%s\n' "${cascade_runtime_dump}" | grep -q '^repo=chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4$' \
  || fail "runtime must expose the Cascade repo when that model is active"
printf '%s\n' "${cascade_runtime_dump}" | grep -q '^revision=80ee3ccfe8cb5eb019a0cde78449e8b197a0155f$' \
  || fail "runtime must expose the pinned Cascade revision when that model is active"
ok "runtime derives NVFP4 defaults from the active TRT model catalog entry"

AGENTIC_PROFILE=rootless-dev \
AGENTIC_ROOT="${runtime_root}" \
COMPOSE_PROFILES=trt \
TRTLLM_ACTIVE_MODEL_KEY=nemotron-cascade-30b \
TRTLLM_MODELS="https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4" \
TRTLLM_NVFP4_PREPARE_SOURCE_DIR="${fixture_cascade_source}" \
bash "${bootstrap_script}" \
  || fail "Cascade NVFP4 bootstrap script failed on local fixture source"

cascade_target_dir="${runtime_root}/trtllm/models/cascade_30b_nvfp4"
[[ -f "${cascade_target_dir}/config.json" ]] || fail "Cascade bootstrap did not populate config.json"
[[ -f "${cascade_target_dir}/model.safetensors.index.json" ]] || fail "Cascade bootstrap did not populate model.safetensors.index.json"
[[ -f "${cascade_target_dir}/model-00001-of-00001.safetensors" ]] || fail "Cascade bootstrap did not populate referenced safetensor shard"
ok "NVFP4 bootstrap also populates the local Cascade directory"

rm -rf "${fixture_source}"
rm -rf "${fixture_cascade_source}"
AGENTIC_PROFILE=rootless-dev \
AGENTIC_ROOT="${runtime_root}" \
COMPOSE_PROFILES=trt \
TRTLLM_MODELS="https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4" \
bash "${bootstrap_script}" \
  || fail "NVFP4 bootstrap must be idempotent once the payload is already complete"
ok "NVFP4 bootstrap is idempotent after the model payload is complete"

compose_dump="$(docker compose --profile trt -f "${compose_file}" config 2>/dev/null)"
printf '%s\n' "${compose_dump}" | grep -q 'TRTLLM_NVFP4_HF_REPO: chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4' \
  || fail "compose config must pass TRTLLM_NVFP4_HF_REPO into the trtllm container"
printf '%s\n' "${compose_dump}" | grep -q 'TRTLLM_NVFP4_HF_REVISION: 80ee3ccfe8cb5eb019a0cde78449e8b197a0155f' \
  || fail "compose config must pass TRTLLM_NVFP4_HF_REVISION into the trtllm container"
ok "compose config passes strict NVFP4 repo metadata into the trtllm container"

ok "C5_trtllm_nvfp4_bootstrap passed"
