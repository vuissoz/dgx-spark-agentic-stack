#!/usr/bin/env bash
set -euo pipefail

seed_custom_nodes() {
  local defaults_dir="/opt/comfyui-defaults/custom_nodes"
  local runtime_dir="/opt/comfyui/custom_nodes"

  [[ -d "${defaults_dir}" ]] || return 0
  mkdir -p "${runtime_dir}"

  if [[ -z "$(ls -A "${runtime_dir}" 2>/dev/null || true)" ]]; then
    cp -a "${defaults_dir}/." "${runtime_dir}/"
    return 0
  fi

  if [[ -d "${defaults_dir}/ComfyUI-Manager" && ! -d "${runtime_dir}/ComfyUI-Manager" ]]; then
    cp -a "${defaults_dir}/ComfyUI-Manager" "${runtime_dir}/ComfyUI-Manager"
  fi
}

seed_custom_nodes

if [[ "${1:-}" == "python3" && "${2:-}" == "main.py" ]]; then
  if ! printf ' %s ' "$*" | grep -q ' --cpu '; then
    if ! python3 - <<'PY'
import sys
import torch

sys.exit(0 if torch.cuda.is_available() else 1)
PY
    then
      echo "WARN: torch CUDA backend unavailable; starting ComfyUI with --cpu fallback" >&2
      set -- "$@" --cpu
    fi
  fi
fi

exec "$@"
