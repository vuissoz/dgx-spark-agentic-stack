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

resolve_comfyui_port() {
  local previous=""
  local token
  for token in "$@"; do
    if [[ "${previous}" == "--port" ]]; then
      printf '%s\n' "${token}"
      return 0
    fi
    case "${token}" in
      --port=*)
        printf '%s\n' "${token#--port=}"
        return 0
        ;;
    esac
    previous="${token}"
  done

  printf '8188\n'
}

ensure_manager_log_compat_symlink() {
  local port="$1"
  local user_dir="/comfyui/user"
  local canonical_log="${user_dir}/comfyui_${port}.log"
  local compat_log="${user_dir}/comfyui.log"

  mkdir -p "${user_dir}"
  if [[ ! -e "${compat_log}" ]]; then
    ln -s "$(basename "${canonical_log}")" "${compat_log}" || true
  fi
}

seed_custom_nodes

if [[ "${1:-}" == "python3" && "${2:-}" == "main.py" ]]; then
  comfyui_port="$(resolve_comfyui_port "$@")"
  ensure_manager_log_compat_symlink "${comfyui_port}"

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
