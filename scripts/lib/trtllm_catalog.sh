#!/usr/bin/env bash

trtllm_strip_hf_url() {
  local candidate="${1:-}"
  candidate="${candidate%/}"
  if [[ "${candidate}" == https://huggingface.co/* ]]; then
    candidate="${candidate#https://huggingface.co/}"
  fi
  printf '%s\n' "${candidate}"
}

trtllm_model_default_key() {
  printf '%s\n' "nemotron-super-120b"
}

trtllm_catalog_rows() {
  cat <<'EOF'
nemotron-super-120b|https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4|nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4|b1ffe4992d7db6d768453a551a656b8d12c638fb|/models/super_fp4|Nemotron 3 Super 120B A12B NVFP4
nemotron-cascade-30b|https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4|chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4|80ee3ccfe8cb5eb019a0cde78449e8b197a0155f|/models/cascade_30b_nvfp4|Nemotron Cascade 2 30B A3B NVFP4
EOF
}

_trtllm_catalog_row() {
  local wanted_key="$1"
  local key url repo revision local_dir label

  while IFS='|' read -r key url repo revision local_dir label; do
    [[ "${key}" == "${wanted_key}" ]] || continue
    printf '%s|%s|%s|%s|%s|%s\n' "${key}" "${url}" "${repo}" "${revision}" "${local_dir}" "${label}"
    return 0
  done < <(trtllm_catalog_rows)

  return 1
}

trtllm_model_keys() {
  local key _url _repo _revision _local_dir _label
  while IFS='|' read -r key _url _repo _revision _local_dir _label; do
    printf '%s\n' "${key}"
  done < <(trtllm_catalog_rows)
}

trtllm_model_exists() {
  _trtllm_catalog_row "$1" >/dev/null 2>&1
}

trtllm_model_resolve_key() {
  local input="${1:-}"
  local stripped_input
  local key url repo _revision local_dir _label

  stripped_input="$(trtllm_strip_hf_url "${input}")"
  while IFS='|' read -r key url repo _revision local_dir _label; do
    if [[ "${input}" == "${key}" || "${input}" == "${url}" || "${stripped_input}" == "${repo}" || "${input}" == "${local_dir}" ]]; then
      printf '%s\n' "${key}"
      return 0
    fi
  done < <(trtllm_catalog_rows)

  return 1
}

trtllm_model_field() {
  local key="$1"
  local field="$2"
  local row row_key url repo revision local_dir label

  row="$(_trtllm_catalog_row "${key}")" || return 1
  IFS='|' read -r row_key url repo revision local_dir label <<<"${row}"

  case "${field}" in
    key) printf '%s\n' "${row_key}" ;;
    url) printf '%s\n' "${url}" ;;
    repo) printf '%s\n' "${repo}" ;;
    revision) printf '%s\n' "${revision}" ;;
    local_dir) printf '%s\n' "${local_dir}" ;;
    label) printf '%s\n' "${label}" ;;
    *)
      return 1
      ;;
  esac
}

trtllm_model_matches_request() {
  local key="$1"
  local requested="${2:-}"
  local url repo local_dir stripped_requested

  url="$(trtllm_model_field "${key}" url)" || return 1
  repo="$(trtllm_model_field "${key}" repo)" || return 1
  local_dir="$(trtllm_model_field "${key}" local_dir)" || return 1
  stripped_requested="$(trtllm_strip_hf_url "${requested}")"

  [[ "${requested}" == "${url}" || "${stripped_requested}" == "${repo}" || "${requested}" == "${local_dir}" ]]
}

trtllm_model_host_dir() {
  local key="$1"
  local container_dir host_root

  container_dir="$(trtllm_model_field "${key}" local_dir)" || return 1
  host_root="${AGENTIC_ROOT:-/srv/agentic}/trtllm/models"

  if [[ "${container_dir}" == "/models" ]]; then
    printf '%s\n' "${host_root}"
    return 0
  fi
  if [[ "${container_dir}" == /models/* ]]; then
    printf '%s\n' "${host_root}${container_dir#/models}"
    return 0
  fi

  return 1
}
