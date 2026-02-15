#!/usr/bin/env bash
set -euo pipefail

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
AGENT_RUNTIME_UID="${AGENT_RUNTIME_UID:-1000}"
AGENT_RUNTIME_GID="${AGENT_RUNTIME_GID:-1000}"

log() {
  echo "INFO: $*"
}

ensure_dir() {
  local path="$1"
  local mode="$2"
  install -d -m "${mode}" "${path}"
  chmod "${mode}" "${path}"
}

main() {
  local -a readonly_dirs=(
    "${AGENTIC_ROOT}/claude"
    "${AGENTIC_ROOT}/codex"
    "${AGENTIC_ROOT}/opencode"
    "${AGENTIC_ROOT}/shared-ro"
  )

  local -a writable_dirs=(
    "${AGENTIC_ROOT}/claude/state"
    "${AGENTIC_ROOT}/claude/logs"
    "${AGENTIC_ROOT}/claude/workspaces"
    "${AGENTIC_ROOT}/codex/state"
    "${AGENTIC_ROOT}/codex/logs"
    "${AGENTIC_ROOT}/codex/workspaces"
    "${AGENTIC_ROOT}/opencode/state"
    "${AGENTIC_ROOT}/opencode/logs"
    "${AGENTIC_ROOT}/opencode/workspaces"
    "${AGENTIC_ROOT}/shared-rw"
  )

  local dir
  for dir in "${readonly_dirs[@]}"; do
    ensure_dir "${dir}" 0750
  done

  for dir in "${writable_dirs[@]}"; do
    ensure_dir "${dir}" 0770
  done

  if [[ "${EUID}" -eq 0 ]]; then
    for dir in "${readonly_dirs[@]}"; do
      chown "root:${AGENT_RUNTIME_GID}" "${dir}"
    done
    for dir in "${writable_dirs[@]}"; do
      chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${dir}"
    done
  fi

  log "agents runtime initialized at ${AGENTIC_ROOT} (uid=${AGENT_RUNTIME_UID}, gid=${AGENT_RUNTIME_GID})"
}

main "$@"
