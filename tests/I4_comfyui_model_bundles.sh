#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/scripts/comfyui_model_bundle.sh"
agent_script="${repo_root}/scripts/agent.sh"
allowlist="${repo_root}/examples/core/allowlist.txt"

[[ -x "${script}" ]] || { echo "FAIL: bundle script is not executable" >&2; exit 1; }
bash -n "${script}"

docker() {
  [[ "${1:-}" == "ps" ]] || return 1
  printf 'test-comfyui-container\n'
}
export -f docker

for bundle in stable-audio-3 ace-step-v1 ace-step-1.5; do
  output="$(AGENTIC_COMPOSE_PROJECT=agentic-dev "${script}" "${bundle}" --dry-run)"
  [[ "${output}" == "dry-run: bundle=${bundle} download=0 force=0" ]] \
    || { echo "FAIL: unexpected ${bundle} dry-run output: ${output}" >&2; exit 1; }
done

rg -qF 'minimax_h3_audio_vae_fp32.safetensors' "${script}"
rg -qF 'minimax_h3_fl2va_pruned_int8_convrot.safetensors' "${script}"
rg -qF 'Flux2TurboComfyv2.safetensors' "${script}"
rg -qF 'mistral_3_small_flux2_fp8.safetensors' "${script}"
rg -qF 'stable_audio_3_medium.safetensors' "${script}"
rg -qF 'qwen3.5_2b_bf16.safetensors' "${script}"
rg -qF 't5gemma_b_b_ul2.safetensors' "${script}"
rg -qF 'ace_step_v1_3.5b.safetensors' "${script}"
rg -qF 'ace_1.5_vae.safetensors' "${script}"
rg -qF 'qwen_0.6b_ace15.safetensors' "${script}"
rg -qF 'qwen_4b_ace15.safetensors' "${script}"
rg -qF 'acestep_v1.5_xl_sft_bf16.safetensors' "${script}"
rg -qF 'ace_step_1.5_turbo_aio.safetensors' "${script}"
rg -qF 'fcntl.LOCK_EX | fcntl.LOCK_NB' "${script}"
rg -qF 'bundle installer already running' "${script}"
rg -qF 'agent comfyui <minimax-h3|flux2-dev|stable-audio-3|ace-step-v1|ace-step-1.5>' "${agent_script}"
rg -qxF 'us.aws.cdn.hf.co' "${allowlist}"

echo "PASS: ComfyUI image, video, and audio bundle commands are wired"
