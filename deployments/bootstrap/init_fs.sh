#!/usr/bin/env bash
set -euo pipefail

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
AGENTIC_GROUP="${AGENTIC_GROUP:-agentic}"
AGENTIC_SKIP_GROUP_CREATE="${AGENTIC_SKIP_GROUP_CREATE:-0}"

log() {
  echo "INFO: $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ensure_group() {
  if getent group "${AGENTIC_GROUP}" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${AGENTIC_SKIP_GROUP_CREATE}" == "1" ]]; then
    log "group '${AGENTIC_GROUP}' does not exist and AGENTIC_SKIP_GROUP_CREATE=1; continuing without group creation"
    return 0
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    die "group '${AGENTIC_GROUP}' is missing. Re-run with sudo or set AGENTIC_SKIP_GROUP_CREATE=1 for non-root test runs."
  fi

  groupadd --system "${AGENTIC_GROUP}"
  log "created system group '${AGENTIC_GROUP}'"
}

ensure_dir() {
  local path="$1"
  local mode="$2"

  install -d -m "${mode}" "${path}"

  if getent group "${AGENTIC_GROUP}" >/dev/null 2>&1; then
    if [[ "${EUID}" -eq 0 ]]; then
      chown root:"${AGENTIC_GROUP}" "${path}"
    fi
    chgrp "${AGENTIC_GROUP}" "${path}" 2>/dev/null || true
  fi

  chmod "${mode}" "${path}"
}

ensure_secret_files_mode() {
  local secrets_dir="$1"

  while IFS= read -r file; do
    chmod 600 "${file}"
  done < <(find "${secrets_dir}" -maxdepth 1 -type f)
}

main() {
  ensure_group

  local -a base_dirs=(
    "${AGENTIC_ROOT}"
    "${AGENTIC_ROOT}/deployments"
    "${AGENTIC_ROOT}/deployments/releases"
    "${AGENTIC_ROOT}/deployments/current"
    "${AGENTIC_ROOT}/bin"
    "${AGENTIC_ROOT}/tests"
    "${AGENTIC_ROOT}/secrets"
    "${AGENTIC_ROOT}/ollama"
    "${AGENTIC_ROOT}/gate"
    "${AGENTIC_ROOT}/gate/state"
    "${AGENTIC_ROOT}/gate/logs"
    "${AGENTIC_ROOT}/proxy"
    "${AGENTIC_ROOT}/proxy/config"
    "${AGENTIC_ROOT}/proxy/logs"
    "${AGENTIC_ROOT}/dns"
    "${AGENTIC_ROOT}/openwebui"
    "${AGENTIC_ROOT}/openhands"
    "${AGENTIC_ROOT}/comfyui"
    "${AGENTIC_ROOT}/comfyui/models"
    "${AGENTIC_ROOT}/comfyui/input"
    "${AGENTIC_ROOT}/comfyui/output"
    "${AGENTIC_ROOT}/comfyui/user"
    "${AGENTIC_ROOT}/rag"
    "${AGENTIC_ROOT}/rag/qdrant"
    "${AGENTIC_ROOT}/rag/docs"
    "${AGENTIC_ROOT}/rag/scripts"
    "${AGENTIC_ROOT}/monitoring"
    "${AGENTIC_ROOT}/claude"
    "${AGENTIC_ROOT}/claude/state"
    "${AGENTIC_ROOT}/claude/logs"
    "${AGENTIC_ROOT}/claude/workspaces"
    "${AGENTIC_ROOT}/codex"
    "${AGENTIC_ROOT}/codex/state"
    "${AGENTIC_ROOT}/codex/logs"
    "${AGENTIC_ROOT}/codex/workspaces"
    "${AGENTIC_ROOT}/opencode"
    "${AGENTIC_ROOT}/opencode/state"
    "${AGENTIC_ROOT}/opencode/logs"
    "${AGENTIC_ROOT}/opencode/workspaces"
    "${AGENTIC_ROOT}/shared-ro"
    "${AGENTIC_ROOT}/shared-rw"
  )

  local dir
  for dir in "${base_dirs[@]}"; do
    ensure_dir "${dir}" 0750
  done

  local -a writable_dirs=(
    "${AGENTIC_ROOT}/gate/state"
    "${AGENTIC_ROOT}/gate/logs"
    "${AGENTIC_ROOT}/proxy/logs"
    "${AGENTIC_ROOT}/claude/state"
    "${AGENTIC_ROOT}/claude/logs"
    "${AGENTIC_ROOT}/claude/workspaces"
    "${AGENTIC_ROOT}/codex/state"
    "${AGENTIC_ROOT}/codex/logs"
    "${AGENTIC_ROOT}/codex/workspaces"
    "${AGENTIC_ROOT}/opencode/state"
    "${AGENTIC_ROOT}/opencode/logs"
    "${AGENTIC_ROOT}/opencode/workspaces"
    "${AGENTIC_ROOT}/comfyui/models"
    "${AGENTIC_ROOT}/comfyui/input"
    "${AGENTIC_ROOT}/comfyui/output"
    "${AGENTIC_ROOT}/comfyui/user"
    "${AGENTIC_ROOT}/rag/qdrant"
    "${AGENTIC_ROOT}/shared-rw"
  )

  for dir in "${writable_dirs[@]}"; do
    ensure_dir "${dir}" 0770
  done

  ensure_dir "${AGENTIC_ROOT}/secrets" 0700
  ensure_secret_files_mode "${AGENTIC_ROOT}/secrets"

  log "filesystem bootstrap completed for ${AGENTIC_ROOT}"
}

main "$@"
