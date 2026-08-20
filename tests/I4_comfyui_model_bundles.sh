#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/scripts/comfyui_model_bundle.sh"
agent_script="${repo_root}/scripts/agent.sh"
allowlist="${repo_root}/examples/core/allowlist.txt"

[[ -x "${script}" ]] || { echo "FAIL: bundle script is not executable" >&2; exit 1; }
bash -n "${script}"

rg -qF 'minimax_h3_audio_vae_fp32.safetensors' "${script}"
rg -qF 'minimax_h3_fl2va_pruned_int8_convrot.safetensors' "${script}"
rg -qF 'Flux2TurboComfyv2.safetensors' "${script}"
rg -qF 'mistral_3_small_flux2_fp8.safetensors' "${script}"
rg -qF 'agent comfyui <minimax-h3|flux2-dev>' "${agent_script}"
rg -qxF 'us.aws.cdn.hf.co' "${allowlist}"

echo "PASS: ComfyUI MiniMax-H3 and Flux.2 bundle commands are wired"
