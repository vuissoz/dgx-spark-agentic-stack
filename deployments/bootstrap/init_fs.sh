#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

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
  if [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]]; then
    log "profile rootless-dev: skip system group management"
    return 0
  fi

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

  if [[ "${AGENTIC_PROFILE}" != "rootless-dev" ]] && getent group "${AGENTIC_GROUP}" >/dev/null 2>&1; then
    if [[ "${EUID}" -eq 0 ]]; then
      chown root:"${AGENTIC_GROUP}" "${path}"
    fi
    chgrp "${AGENTIC_GROUP}" "${path}" 2>/dev/null || true
  fi

  chmod "${mode}" "${path}"
}

ensure_secret_files_mode() {
  local secrets_dir="$1"

  if [[ ! -d "${secrets_dir}" ]]; then
    return 0
  fi

  # Ensure all runtime secret files are always restrictive (including subdirectories like runtime/)
  find "${secrets_dir}" -type f -exec chmod 0600 {} +
}

main() {
  log "bootstrap profile=${AGENTIC_PROFILE} root=${AGENTIC_ROOT}"
  ensure_group

  local -a base_dirs=(
    "${AGENTIC_ROOT}"
    "${AGENTIC_ROOT}/deployments"
    "${AGENTIC_ROOT}/deployments/releases"
    "${AGENTIC_ROOT}/deployments/current"
    "${AGENTIC_ROOT}/bin"
    "${AGENTIC_ROOT}/tests"
    "${AGENTIC_ROOT}/secrets"
    "${AGENTIC_ROOT}/secrets/runtime"
    "${AGENTIC_ROOT}/ollama"
    "${AGENTIC_ROOT}/gate"
    "${AGENTIC_ROOT}/gate/config"
    "${AGENTIC_ROOT}/gate/state"
    "${AGENTIC_ROOT}/gate/logs"
    "${AGENTIC_ROOT}/gate/mcp"
    "${AGENTIC_ROOT}/gate/mcp/state"
    "${AGENTIC_ROOT}/gate/mcp/logs"
    "${AGENTIC_ROOT}/trtllm"
    "${AGENTIC_ROOT}/trtllm/models"
    "${AGENTIC_ROOT}/trtllm/state"
    "${AGENTIC_ROOT}/trtllm/logs"
    "${AGENTIC_ROOT}/proxy"
    "${AGENTIC_ROOT}/proxy/config"
    "${AGENTIC_ROOT}/proxy/logs"
    "${AGENTIC_ROOT}/dns"
    "${AGENTIC_ROOT}/openwebui"
    "${AGENTIC_ROOT}/openhands"
    "${AGENTIC_ROOT}/openhands/state"
    "${AGENTIC_ROOT}/openhands/logs"
    "${AGENTIC_OPENHANDS_WORKSPACES_DIR}"
    "${AGENTIC_ROOT}/comfyui"
    "${AGENTIC_ROOT}/comfyui/models"
    "${AGENTIC_ROOT}/comfyui/input"
    "${AGENTIC_ROOT}/comfyui/output"
    "${AGENTIC_ROOT}/comfyui/user"
    "${AGENTIC_ROOT}/comfyui/custom_nodes"
    "${AGENTIC_ROOT}/rag"
    "${AGENTIC_ROOT}/rag/qdrant"
    "${AGENTIC_ROOT}/rag/qdrant-snapshots"
    "${AGENTIC_ROOT}/rag/docs"
    "${AGENTIC_ROOT}/rag/scripts"
    "${AGENTIC_ROOT}/rag/retriever"
    "${AGENTIC_ROOT}/rag/retriever/state"
    "${AGENTIC_ROOT}/rag/retriever/logs"
    "${AGENTIC_ROOT}/rag/worker"
    "${AGENTIC_ROOT}/rag/worker/state"
    "${AGENTIC_ROOT}/rag/worker/logs"
    "${AGENTIC_ROOT}/rag/opensearch"
    "${AGENTIC_ROOT}/rag/opensearch-logs"
    "${AGENTIC_ROOT}/monitoring"
    "${AGENTIC_ROOT}/openclaw"
    "${AGENTIC_ROOT}/openclaw/config"
    "${AGENTIC_ROOT}/openclaw/state"
    "${AGENTIC_ROOT}/openclaw/logs"
    "${AGENTIC_OPENCLAW_WORKSPACES_DIR}"
    "${AGENTIC_ROOT}/openclaw/relay"
    "${AGENTIC_ROOT}/openclaw/relay/state"
    "${AGENTIC_ROOT}/openclaw/relay/logs"
    "${AGENTIC_ROOT}/openclaw/sandbox"
    "${AGENTIC_ROOT}/openclaw/sandbox/state"
    "${AGENTIC_ROOT}/openclaw/sandbox/workspaces"
    "${AGENTIC_ROOT}/optional"
    "${AGENTIC_ROOT}/optional/mcp"
    "${AGENTIC_ROOT}/optional/mcp/config"
    "${AGENTIC_ROOT}/optional/mcp/state"
    "${AGENTIC_ROOT}/optional/mcp/logs"
    "${AGENTIC_ROOT}/optional/pi-mono"
    "${AGENTIC_ROOT}/optional/pi-mono/state"
    "${AGENTIC_ROOT}/optional/pi-mono/logs"
    "${AGENTIC_PI_MONO_WORKSPACES_DIR}"
    "${AGENTIC_ROOT}/optional/goose"
    "${AGENTIC_ROOT}/optional/goose/state"
    "${AGENTIC_ROOT}/optional/goose/logs"
    "${AGENTIC_GOOSE_WORKSPACES_DIR}"
    "${AGENTIC_ROOT}/optional/portainer"
    "${AGENTIC_ROOT}/optional/portainer/data"
    "${AGENTIC_ROOT}/optional/portainer/logs"
    "${AGENTIC_AGENT_WORKSPACES_ROOT}"
    "${AGENTIC_CLAUDE_WORKSPACES_DIR}"
    "${AGENTIC_CODEX_WORKSPACES_DIR}"
    "${AGENTIC_OPENCODE_WORKSPACES_DIR}"
    "${AGENTIC_VIBESTRAL_WORKSPACES_DIR}"
    "${AGENTIC_ROOT}/claude"
    "${AGENTIC_ROOT}/claude/state"
    "${AGENTIC_ROOT}/claude/logs"
    "${AGENTIC_ROOT}/codex"
    "${AGENTIC_ROOT}/codex/state"
    "${AGENTIC_ROOT}/codex/logs"
    "${AGENTIC_ROOT}/opencode"
    "${AGENTIC_ROOT}/opencode/state"
    "${AGENTIC_ROOT}/opencode/logs"
    "${AGENTIC_ROOT}/vibestral"
    "${AGENTIC_ROOT}/vibestral/state"
    "${AGENTIC_ROOT}/vibestral/logs"
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
    "${AGENTIC_ROOT}/gate/mcp/state"
    "${AGENTIC_ROOT}/gate/mcp/logs"
    "${AGENTIC_ROOT}/trtllm/models"
    "${AGENTIC_ROOT}/trtllm/state"
    "${AGENTIC_ROOT}/trtllm/logs"
    "${AGENTIC_ROOT}/proxy/logs"
    "${AGENTIC_ROOT}/claude/state"
    "${AGENTIC_ROOT}/claude/logs"
    "${AGENTIC_ROOT}/codex/state"
    "${AGENTIC_ROOT}/codex/logs"
    "${AGENTIC_ROOT}/opencode/state"
    "${AGENTIC_ROOT}/opencode/logs"
    "${AGENTIC_ROOT}/vibestral/state"
    "${AGENTIC_ROOT}/vibestral/logs"
    "${AGENTIC_ROOT}/openhands/state"
    "${AGENTIC_ROOT}/openhands/logs"
    "${AGENTIC_OPENHANDS_WORKSPACES_DIR}"
    "${AGENTIC_CLAUDE_WORKSPACES_DIR}"
    "${AGENTIC_CODEX_WORKSPACES_DIR}"
    "${AGENTIC_OPENCODE_WORKSPACES_DIR}"
    "${AGENTIC_VIBESTRAL_WORKSPACES_DIR}"
    "${AGENTIC_ROOT}/comfyui/models"
    "${AGENTIC_ROOT}/comfyui/input"
    "${AGENTIC_ROOT}/comfyui/output"
    "${AGENTIC_ROOT}/comfyui/user"
    "${AGENTIC_ROOT}/comfyui/custom_nodes"
    "${AGENTIC_ROOT}/rag/qdrant"
    "${AGENTIC_ROOT}/rag/qdrant-snapshots"
    "${AGENTIC_ROOT}/rag/retriever/state"
    "${AGENTIC_ROOT}/rag/retriever/logs"
    "${AGENTIC_ROOT}/rag/worker/state"
    "${AGENTIC_ROOT}/rag/worker/logs"
    "${AGENTIC_ROOT}/rag/opensearch"
    "${AGENTIC_ROOT}/rag/opensearch-logs"
    "${AGENTIC_ROOT}/openclaw/state"
    "${AGENTIC_OPENCLAW_WORKSPACES_DIR}"
    "${AGENTIC_ROOT}/openclaw/sandbox/state"
    "${AGENTIC_ROOT}/openclaw/sandbox/workspaces"
    "${AGENTIC_ROOT}/openclaw/relay/state"
    "${AGENTIC_ROOT}/openclaw/relay/logs"
    "${AGENTIC_ROOT}/openclaw/logs"
    "${AGENTIC_ROOT}/optional/mcp/state"
    "${AGENTIC_ROOT}/optional/mcp/logs"
    "${AGENTIC_ROOT}/optional/pi-mono/state"
    "${AGENTIC_ROOT}/optional/pi-mono/logs"
    "${AGENTIC_PI_MONO_WORKSPACES_DIR}"
    "${AGENTIC_ROOT}/optional/goose/state"
    "${AGENTIC_ROOT}/optional/goose/logs"
    "${AGENTIC_GOOSE_WORKSPACES_DIR}"
    "${AGENTIC_ROOT}/optional/portainer/data"
    "${AGENTIC_ROOT}/optional/portainer/logs"
    "${AGENTIC_ROOT}/shared-rw"
  )

  for dir in "${writable_dirs[@]}"; do
    ensure_dir "${dir}" 0770
  done

  ensure_dir "${AGENTIC_ROOT}/secrets" 0700
  ensure_dir "${AGENTIC_ROOT}/secrets/runtime" 0700
  ensure_secret_files_mode "${AGENTIC_ROOT}/secrets"

  log "filesystem bootstrap completed for ${AGENTIC_ROOT}"
}

main "$@"
