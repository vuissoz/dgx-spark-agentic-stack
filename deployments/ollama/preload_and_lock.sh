#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/../../scripts/lib/runtime.sh"

AGENT_RUNTIME_ENV_FILE="${AGENTIC_ROOT}/deployments/runtime.env"
CORE_COMPOSE_FILE="${AGENTIC_COMPOSE_DIR}/compose.core.yml"
OLLAMA_API_URL="${OLLAMA_API_URL:-http://127.0.0.1:11434}"

generate_model="${OLLAMA_PRELOAD_GENERATE_MODEL:-${AGENTIC_DEFAULT_MODEL:-llama3.1:8b}}"
embed_model="${OLLAMA_PRELOAD_EMBED_MODEL:-qwen3-embedding:0.6b}"
budget_gb="${OLLAMA_MODEL_STORE_BUDGET_GB:-12}"
lock_ro_after_preload=1

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "INFO: $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

usage() {
  cat <<USAGE
Usage:
  preload_and_lock.sh [--generate-model <model>] [--embed-model <model>] [--budget-gb <int>] [--no-lock-ro]

Defaults:
  --generate-model ${generate_model}
  --embed-model    ${embed_model}
  --budget-gb      ${budget_gb}
Behavior:
  - preserves current Ollama mount mode by default (restores it if a temporary switch is needed)
  - --no-lock-ro keeps rw after preload when a temporary switch from ro occurred
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --generate-model)
        [[ $# -ge 2 ]] || die "--generate-model requires a value"
        generate_model="$2"
        shift 2
        ;;
      --embed-model)
        [[ $# -ge 2 ]] || die "--embed-model requires a value"
        embed_model="$2"
        shift 2
        ;;
      --budget-gb)
        [[ $# -ge 2 ]] || die "--budget-gb requires a value"
        budget_gb="$2"
        shift 2
        ;;
      --no-lock-ro)
        lock_ro_after_preload=0
        shift
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

ensure_runtime_env_file() {
  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${AGENT_RUNTIME_ENV_FILE}"
  chmod 0640 "${AGENT_RUNTIME_ENV_FILE}" || true
}

set_runtime_env_value() {
  local key="$1"
  local value="$2"

  if grep -Eq "^${key}=" "${AGENT_RUNTIME_ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|g" "${AGENT_RUNTIME_ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${AGENT_RUNTIME_ENV_FILE}"
  fi
}

service_container_id() {
  local service="$1"
  docker ps \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}' | head -n 1
}

normalize_mount_mode() {
  local mode="${1:-}"
  case "${mode}" in
    rw|ro)
      printf '%s\n' "${mode}"
      ;;
    *)
      return 1
      ;;
  esac
}

wait_for_ollama_api() {
  local timeout_seconds="${1:-120}"
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    if curl -fsS --max-time 3 "${OLLAMA_API_URL}/api/version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    ((elapsed += 1))
  done

  return 1
}

container_mount_mode() {
  local container_id="$1"
  local rw_flag
  rw_flag="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "'"${OLLAMA_CONTAINER_MODELS_PATH}"'"}}{{println .RW}}{{end}}{{end}}' "${container_id}" | head -n 1)"
  case "${rw_flag}" in
    true) printf 'rw\n' ;;
    false) printf 'ro\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

models_mount_is_readonly() {
  local container_id="$1"
  [[ "$(container_mount_mode "${container_id}")" == "ro" ]]
}

apply_ollama_mount_mode() {
  local mode="$1"
  [[ -f "${CORE_COMPOSE_FILE}" ]] || die "core compose file not found: ${CORE_COMPOSE_FILE}"

  OLLAMA_MODELS_MOUNT_MODE="${mode}" \
    docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${CORE_COMPOSE_FILE}" up -d --force-recreate ollama
  set_runtime_env_value "OLLAMA_MODELS_MOUNT_MODE" "${mode}"
}

ensure_ollama_running() {
  [[ -f "${CORE_COMPOSE_FILE}" ]] || die "core compose file not found: ${CORE_COMPOSE_FILE}"
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${CORE_COMPOSE_FILE}" up -d ollama
}

detect_initial_mount_mode() {
  local configured_mode="${OLLAMA_MODELS_MOUNT_MODE:-rw}"
  local normalized_configured_mode
  local container_id
  local runtime_mode

  normalized_configured_mode="$(normalize_mount_mode "${configured_mode}")" \
    || die "invalid OLLAMA_MODELS_MOUNT_MODE='${configured_mode}' (expected rw or ro)"

  container_id="$(service_container_id ollama)"
  if [[ -n "${container_id}" ]]; then
    runtime_mode="$(container_mount_mode "${container_id}")"
    if [[ "${runtime_mode}" == "rw" || "${runtime_mode}" == "ro" ]]; then
      printf '%s\n' "${runtime_mode}"
      return 0
    fi
  fi

  printf '%s\n' "${normalized_configured_mode}"
}

ensure_models_dir_writable() {
  local container_id="$1"
  docker exec "${container_id}" sh -lc "test -w '${OLLAMA_CONTAINER_MODELS_PATH}'" \
    || die "ollama model path is not writable in container (${OLLAMA_CONTAINER_MODELS_PATH}); check host path permissions for ${OLLAMA_MODELS_DIR}"
}

to_bytes() {
  local gib="$1"
  printf '%s\n' "$((gib * 1024 * 1024 * 1024))"
}

main() {
  parse_args "$@"

  require_cmd docker
  require_cmd curl
  require_cmd du
  require_cmd df
  require_cmd awk

  [[ "${budget_gb}" =~ ^[0-9]+$ ]] || die "--budget-gb must be an integer"
  (( budget_gb > 0 )) || die "--budget-gb must be > 0"

  install -d -m 0770 "${OLLAMA_MODELS_DIR}"
  ensure_runtime_env_file

  local budget_bytes
  budget_bytes="$(to_bytes "${budget_gb}")"

  local current_size_bytes
  current_size_bytes="$(du -sb "${OLLAMA_MODELS_DIR}" | awk '{print $1}')"
  local avail_bytes
  avail_bytes="$(df -B1 --output=avail "${OLLAMA_MODELS_DIR}" | tail -n 1 | tr -d ' ')"
  local capacity_bytes=$((current_size_bytes + avail_bytes))

  (( current_size_bytes <= budget_bytes )) \
    || die "existing model store already exceeds budget (${current_size_bytes} bytes > ${budget_bytes} bytes)"
  (( capacity_bytes >= budget_bytes )) \
    || die "filesystem capacity is below configured budget (${capacity_bytes} bytes < ${budget_bytes} bytes)"

  local initial_mount_mode
  local switched_mount_mode=0
  local final_mount_mode
  local ollama_cid
  initial_mount_mode="$(detect_initial_mount_mode)"

  if [[ "${initial_mount_mode}" == "rw" ]]; then
    ollama_cid="$(service_container_id ollama)"
    if [[ -n "${ollama_cid}" ]]; then
      log "ollama model mount already rw; skipping mount-mode recreate"
    else
      log "ollama model mount configured as rw; starting ollama without force-recreate"
      ensure_ollama_running
    fi
    final_mount_mode="rw"
    wait_for_ollama_api 180 || die "ollama API did not become ready in rw mode"
  else
    log "switching ollama model mount to read-write for preload (initial mode=${initial_mount_mode})"
    apply_ollama_mount_mode "rw"
    switched_mount_mode=1
    final_mount_mode="rw"
    wait_for_ollama_api 180 || die "ollama API did not become ready after switching to read-write mode"
  fi

  ollama_cid="$(service_container_id ollama)"
  [[ -n "${ollama_cid}" ]] || die "ollama container is not running"
  ensure_models_dir_writable "${ollama_cid}"

  local -A seen_models=()
  local -a model_queue=()
  local model
  for model in "${generate_model}" "${embed_model}"; do
    [[ -n "${model}" ]] || continue
    if [[ -z "${seen_models[${model}]:-}" ]]; then
      model_queue+=("${model}")
      seen_models["${model}"]=1
    fi
  done

  [[ "${#model_queue[@]}" -gt 0 ]] || die "no model selected for preload"

  for model in "${model_queue[@]}"; do
    log "pulling model '${model}'"
    docker exec "${ollama_cid}" ollama pull "${model}"
  done

  local final_size_bytes
  final_size_bytes="$(du -sb "${OLLAMA_MODELS_DIR}" | awk '{print $1}')"
  (( final_size_bytes <= budget_bytes )) \
    || die "model store exceeds configured budget after preload (${final_size_bytes} bytes > ${budget_bytes} bytes)"

  set_runtime_env_value "OLLAMA_PRELOAD_GENERATE_MODEL" "${generate_model}"
  set_runtime_env_value "OLLAMA_PRELOAD_EMBED_MODEL" "${embed_model}"
  set_runtime_env_value "OLLAMA_MODEL_STORE_BUDGET_GB" "${budget_gb}"
  set_runtime_env_value "RAG_EMBED_MODEL" "${embed_model}"

  if [[ "${switched_mount_mode}" -eq 1 ]]; then
    if [[ "${lock_ro_after_preload}" -eq 1 ]]; then
      log "restoring ollama model mount to initial mode (${initial_mount_mode})"
      apply_ollama_mount_mode "${initial_mount_mode}"
      wait_for_ollama_api 180 || die "ollama API did not become ready after restoring initial mode"
      ollama_cid="$(service_container_id ollama)"
      [[ -n "${ollama_cid}" ]] || die "ollama container is not running after mount mode restore"
      if [[ "${initial_mount_mode}" == "ro" ]]; then
        models_mount_is_readonly "${ollama_cid}" || die "ollama model mount is not read-only after restore"
      fi
      final_mount_mode="${initial_mount_mode}"
    else
      log "keeping ollama model mount in read-write mode because --no-lock-ro"
      final_mount_mode="rw"
    fi
  fi

  set_runtime_env_value "OLLAMA_MODELS_MOUNT_MODE" "${final_mount_mode}"

  printf 'OK: ollama preload completed models=%s budget_gb=%s mount_mode=%s size_bytes=%s\n' \
    "$(IFS=,; echo "${model_queue[*]}")" \
    "${budget_gb}" \
    "${final_mount_mode}" \
    "${final_size_bytes}"
}

main "$@"
