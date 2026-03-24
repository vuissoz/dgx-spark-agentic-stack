#!/usr/bin/env bash
set -euo pipefail

ensure_runtime_tree() {
  mkdir -p \
    /comfyui/models \
    /comfyui/input \
    /comfyui/output \
    /comfyui/user \
    /comfyui/custom_nodes \
    /comfyui/user/agentic-runtime
}

seed_custom_nodes() {
  local defaults_dir="/opt/comfyui-defaults/custom_nodes"
  local runtime_dir="/comfyui/custom_nodes"

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

write_torch_runtime_diagnostics() {
  local diagnostics_file="/comfyui/user/agentic-runtime/torch-runtime.json"

  python3 - "${diagnostics_file}" <<'PY' || {
import json
import os
import platform
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
build_info_path = Path("/opt/comfyui-defaults/torch-build.json")
profile = os.environ.get("AGENTIC_PROFILE", "")
machine = platform.machine().lower()

payload = {
    "runtime_profile": profile,
    "runtime_machine": machine,
    "policy": "standard",
    "reason": "no special ComfyUI CUDA policy applied",
    "cpu_fallback_expected": False,
}

if build_info_path.is_file():
    try:
        payload["build"] = json.loads(build_info_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        payload["build"] = {"parse_error": "invalid json"}

try:
    import torch

    payload["torch_version"] = getattr(torch, "__version__", "")
    payload["torch_cuda_version"] = getattr(getattr(torch, "version", None), "cuda", None)
    payload["torch_cuda_compiled"] = bool(payload["torch_cuda_version"])
    try:
        payload["torch_cuda_available"] = bool(torch.cuda.is_available())
    except Exception as exc:  # pragma: no cover - runtime diagnostics best effort
        payload["torch_cuda_available"] = False
        payload["torch_cuda_probe_error"] = str(exc)
except Exception as exc:  # pragma: no cover - runtime diagnostics best effort
    payload["torch_import_error"] = str(exc)
    payload["torch_cuda_available"] = False
    payload["torch_cuda_compiled"] = False

if profile == "rootless-dev" and machine in {"aarch64", "arm64"}:
    if payload.get("torch_cuda_available"):
        payload["policy"] = "effective"
        payload["reason"] = "torch.cuda.is_available() returned true on arm64/rootless-dev"
    else:
        payload["policy"] = "unsupported-explicit"
        payload["reason"] = (
            "effective CUDA backend not detected for ComfyUI on arm64/rootless-dev; "
            "entrypoint will force --cpu fallback"
        )
        payload["cpu_fallback_expected"] = True

output_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
PY
    echo "WARN: failed to write ComfyUI torch runtime diagnostics to ${diagnostics_file}" >&2
    return 0
  }
}

warn_if_arm64_rootless_policy_requires_fallback() {
  local diagnostics_file="/comfyui/user/agentic-runtime/torch-runtime.json"
  local summary

  [[ -f "${diagnostics_file}" ]] || return 0
  summary="$(
    python3 - "${diagnostics_file}" <<'PY' 2>/dev/null || true
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(f"{payload.get('policy', '')}|{payload.get('reason', '')}")
PY
  )"

  if [[ "${summary%%|*}" == "unsupported-explicit" ]]; then
    echo "WARN: ComfyUI CUDA policy is explicit unsupported on arm64/rootless-dev; ${summary#*|}" >&2
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

ensure_runtime_tree
seed_custom_nodes

if [[ "${1:-}" == "python3" && "${2:-}" == "main.py" ]]; then
  comfyui_port="$(resolve_comfyui_port "$@")"
  ensure_manager_log_compat_symlink "${comfyui_port}"
  write_torch_runtime_diagnostics
  warn_if_arm64_rootless_policy_requires_fallback

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
