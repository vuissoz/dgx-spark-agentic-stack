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

prefetch_enabled() {
  case "${TRTLLM_HF_PREFETCH_ENABLED:-auto}" in
    0|false|FALSE|off|OFF|no|NO)
      return 1
      ;;
  esac

  agentic_csv_contains "trt" "${COMPOSE_PROFILES:-}" || return 1

  case "${TRTLLM_HF_PREFETCH_ENABLED:-auto}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
  esac

  [[ "$(trtllm_strip_hf_url "${TRTLLM_MODELS:-}")" == "$(trtllm_exposed_default_handle)" ]]
}

prefetch_repo() {
  printf '%s\n' "${TRTLLM_HF_PREFETCH_REPO:-$(trtllm_exposed_default_handle)}"
}

prefetch_revision() {
  printf '%s\n' "${TRTLLM_HF_PREFETCH_REVISION:-main}"
}

prefetch_cache_root() {
  printf '%s\n' "${AGENTIC_ROOT}/trtllm/models/huggingface"
}

prefetch_repo_cache_dir() {
  local repo_id
  repo_id="$(prefetch_repo)"
  printf '%s\n' "$(prefetch_cache_root)/hub/models--${repo_id//\//--}"
}

copy_source_snapshot() {
  local source_dir="$1"
  local repo_cache_dir="$2"
  local revision="$3"
  local snapshot_dir="${repo_cache_dir}/snapshots/${revision}"

  [[ -d "${source_dir}" ]] || die "TRTLLM_HF_PREFETCH_SOURCE_DIR does not exist: ${source_dir}"
  install -d -m 0770 "${snapshot_dir}" "${repo_cache_dir}/refs"
  cp -a "${source_dir}/." "${snapshot_dir}/"
  printf '%s\n' "${revision}" > "${repo_cache_dir}/refs/main"
}

download_snapshot() {
  local cache_root="$1"
  local repo_id="$2"
  local revision="$3"
  local token_file="${AGENTIC_ROOT}/secrets/runtime/huggingface.token"
  local venv_dir="${AGENTIC_ROOT}/trtllm/state/hfhub-venv"

  [[ -s "${token_file}" ]] || {
    log "skip TRT HF prefetch: missing non-empty ${token_file}"
    return 0
  }

  if [[ ! -x "${venv_dir}/bin/python" ]]; then
    python3 -m venv "${venv_dir}"
  fi
  if ! "${venv_dir}/bin/python" -c 'import huggingface_hub' >/dev/null 2>&1; then
    "${venv_dir}/bin/pip" install 'huggingface_hub>=1.0.0,<2.0.0'
  fi

  export HF_HUB_DISABLE_XET=1
  "${venv_dir}/bin/python" - <<'PY' "${cache_root}" "${token_file}" "${repo_id}" "${revision}" "${TRTLLM_HF_PREFETCH_MAX_WORKERS:-1}"
from huggingface_hub import snapshot_download
import pathlib
import sys

cache_root = pathlib.Path(sys.argv[1])
token_file = pathlib.Path(sys.argv[2])
repo_id = sys.argv[3]
revision = sys.argv[4]
max_workers = int(sys.argv[5])

snapshot_download(
    repo_id=repo_id,
    revision=revision,
    cache_dir=str(cache_root),
    token=token_file.read_text(encoding="utf-8").strip(),
    max_workers=max_workers,
)
PY
}

main() {
  local helper_log="${AGENTIC_ROOT}/trtllm/logs/trtllm-hf-prefetch.log"
  local repo_id revision cache_root repo_cache_dir

  if ! prefetch_enabled; then
    log "skip TRT HF prefetch: current runtime selection does not target the default Nano FP8 alias"
    return 0
  fi

  repo_id="$(prefetch_repo)"
  revision="$(prefetch_revision)"
  cache_root="$(prefetch_cache_root)"
  repo_cache_dir="$(prefetch_repo_cache_dir)"

  install -d -m 0770 "${AGENTIC_ROOT}/trtllm" "${AGENTIC_ROOT}/trtllm/state" "${AGENTIC_ROOT}/trtllm/logs" "${cache_root}"
  exec > >(tee -a "${helper_log}") 2>&1

  log "prefetching TRT HF model repo=${repo_id} revision=${revision} cache_root=${cache_root}"
  if [[ -n "${TRTLLM_HF_PREFETCH_SOURCE_DIR:-}" ]]; then
    copy_source_snapshot "${TRTLLM_HF_PREFETCH_SOURCE_DIR}" "${repo_cache_dir}" "${revision}"
  else
    download_snapshot "${cache_root}" "${repo_id}" "${revision}"
  fi
  log "prefetched TRT HF model repo=${repo_id}"
}

main "$@"
