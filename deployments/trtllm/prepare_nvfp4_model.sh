#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

log() {
  printf 'INFO: %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

resolve_host_target_dir() {
  local container_dir

  if [[ -n "${TRTLLM_NVFP4_LOCAL_MODEL_HOST_DIR:-}" ]]; then
    printf '%s\n' "${TRTLLM_NVFP4_LOCAL_MODEL_HOST_DIR}"
    return 0
  fi

  container_dir="${TRTLLM_NVFP4_LOCAL_MODEL_DIR}"
  if host_dir="$(agentic_trtllm_nvfp4_host_dir "${container_dir}")"; then
    printf '%s\n' "${host_dir}"
    return 0
  fi

  die "TRT local model dir must stay under /models/... or set TRTLLM_NVFP4_LOCAL_MODEL_HOST_DIR explicitly"
}

model_is_active_request() {
  [[ "$(trtllm_strip_hf_url "${TRTLLM_MODELS}")" == "${TRTLLM_NVFP4_HF_REPO}" ]] || [[ "${TRTLLM_MODELS}" == "${TRTLLM_NVFP4_LOCAL_MODEL_DIR}" ]]
}

download_enabled() {
  case "${TRTLLM_NVFP4_PREPARE_ENABLED:-auto}" in
    auto)
      [[ "${TRTLLM_NATIVE_MODEL_POLICY}" == "strict-nvfp4-local-only" ]] \
        && agentic_csv_contains "trt" "${COMPOSE_PROFILES:-}" \
        && model_is_active_request
      ;;
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

model_payload_complete() {
  local target_dir="$1"
  python3 - "${target_dir}" <<'PY'
import json
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
index_path = target / "model.safetensors.index.json"
if not index_path.exists():
    raise SystemExit(1)
payload = json.loads(index_path.read_text(encoding="utf-8"))
weight_map = payload.get("weight_map")
if not isinstance(weight_map, dict) or not weight_map:
    raise SystemExit(1)
required = sorted(set(weight_map.values()))
for rel in required:
    path = target / rel
    if not path.is_file() or path.stat().st_size <= 0:
        raise SystemExit(1)
raise SystemExit(0)
PY
}

prepare_python_venv() {
  local venv_dir="$1"

  if [[ ! -x "${venv_dir}/bin/python" ]]; then
    python3 -m venv "${venv_dir}"
  fi
  if [[ ! -x "${venv_dir}/bin/python" ]]; then
    die "python venv bootstrap failed for ${venv_dir}"
  fi
  if ! "${venv_dir}/bin/python" -c 'import huggingface_hub' >/dev/null 2>&1; then
    "${venv_dir}/bin/pip" install 'huggingface_hub>=1.0.0,<2.0.0'
  fi
}

copy_from_local_source() {
  local source_dir="$1"
  local target_dir="$2"

  [[ -d "${source_dir}" ]] || die "TRTLLM_NVFP4_PREPARE_SOURCE_DIR does not exist: ${source_dir}"
  cp -a "${source_dir}/." "${target_dir}/"
}

download_snapshot() {
  local target_dir="$1"
  local repo_id="$2"
  local revision="$3"
  local token_file="${AGENTIC_ROOT}/secrets/runtime/huggingface.token"
  local venv_dir="${AGENTIC_ROOT}/trtllm/state/hfhub-venv"

  [[ -s "${token_file}" ]] || die "strict TRT NVFP4 bootstrap requires a non-empty ${token_file}"

  prepare_python_venv "${venv_dir}"
  export HF_HUB_DISABLE_XET=1
  "${venv_dir}/bin/python" - <<'PY' "${target_dir}" "${token_file}" "${repo_id}" "${revision}" "${TRTLLM_NVFP4_PREPARE_MAX_WORKERS:-4}"
from huggingface_hub import snapshot_download
import pathlib
import sys

target_dir = pathlib.Path(sys.argv[1])
token_file = pathlib.Path(sys.argv[2])
repo_id = sys.argv[3]
revision = sys.argv[4]
max_workers = int(sys.argv[5])

snapshot_download(
    repo_id=repo_id,
    revision=revision,
    local_dir=str(target_dir),
    token=token_file.read_text(encoding="utf-8").strip(),
    max_workers=max_workers,
)
print(target_dir)
PY
}

prepare_model() {
  local target_dir repo_id revision container_dir
  local log_dir="${AGENTIC_ROOT}/trtllm/logs"
  local lock_dir="${AGENTIC_ROOT}/trtllm/state/nvfp4-prepare.lock"

  if ! download_enabled; then
    log "skip NVFP4 prepare: current TRT runtime selection does not require strict local NVFP4 bootstrap"
    return 0
  fi

  target_dir="$(resolve_host_target_dir)"
  repo_id="${TRTLLM_NVFP4_HF_REPO}"
  revision="${TRTLLM_NVFP4_HF_REVISION}"
  container_dir="${TRTLLM_NVFP4_LOCAL_MODEL_DIR}"
  install -d -m 0770 "${AGENTIC_ROOT}/trtllm" "${AGENTIC_ROOT}/trtllm/state" "${AGENTIC_ROOT}/trtllm/logs"
  install -d -m 0770 "${target_dir}"

  if model_payload_complete "${target_dir}"; then
    log "NVFP4 model is already prepared at ${target_dir}"
    return 0
  fi

  if ! mkdir "${lock_dir}" 2>/dev/null; then
    log "skip NVFP4 prepare: another bootstrap process already owns ${lock_dir}"
    return 0
  fi
  trap "rm -rf -- $(printf '%q' "${lock_dir}")" EXIT

  install -d -m 0750 "${log_dir}"
  exec > >(tee -a "${log_dir}/nvfp4-model-prepare.log") 2>&1

  log "preparing local TRT model repo=${repo_id} target=${target_dir} container_dir=${container_dir}"
  if [[ -n "${TRTLLM_NVFP4_PREPARE_SOURCE_DIR:-}" ]]; then
    copy_from_local_source "${TRTLLM_NVFP4_PREPARE_SOURCE_DIR}" "${target_dir}"
  else
    download_snapshot "${target_dir}" "${repo_id}" "${revision}"
  fi

  model_payload_complete "${target_dir}" || die "local TRT payload remains incomplete after bootstrap: ${target_dir}"
  log "prepared local TRT model under ${target_dir}"
}

main() {
  prepare_model
}

main "$@"
