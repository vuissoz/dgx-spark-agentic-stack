#!/usr/bin/env bash
set -euo pipefail

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
AGENTIC_PROFILE="${AGENTIC_PROFILE:-strict-prod}"
if [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]]; then
  AGENTIC_AGENT_WORKSPACES_ROOT="${AGENTIC_AGENT_WORKSPACES_ROOT:-${AGENTIC_ROOT}/agent-workspaces}"
else
  AGENTIC_AGENT_WORKSPACES_ROOT="${AGENTIC_AGENT_WORKSPACES_ROOT:-${AGENTIC_ROOT}}"
fi
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

ensure_gate_mcp_token() {
  local token_file="${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token"
  local token

  install -d -m 0700 "${AGENTIC_ROOT}/secrets"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets/runtime"

  if [[ ! -s "${token_file}" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      token="$(openssl rand -hex 24)"
    else
      token="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    printf '%s\n' "${token}" >"${token_file}"
  fi

  chmod 0600 "${token_file}"
  if [[ "${EUID}" -eq 0 ]]; then
    chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${token_file}" || true
  fi
}

main() {
  local -a readonly_dirs=(
    "${AGENTIC_ROOT}/claude"
    "${AGENTIC_ROOT}/codex"
    "${AGENTIC_ROOT}/opencode"
    "${AGENTIC_ROOT}/vibestral"
    "${AGENTIC_ROOT}/shared-ro"
  )

  local -a writable_dirs=(
    "${AGENTIC_ROOT}/claude/state"
    "${AGENTIC_ROOT}/claude/logs"
    "${AGENTIC_ROOT}/codex/state"
    "${AGENTIC_ROOT}/codex/logs"
    "${AGENTIC_ROOT}/opencode/state"
    "${AGENTIC_ROOT}/opencode/logs"
    "${AGENTIC_ROOT}/vibestral/state"
    "${AGENTIC_ROOT}/vibestral/logs"
    "${AGENTIC_AGENT_WORKSPACES_ROOT}/claude/workspaces"
    "${AGENTIC_AGENT_WORKSPACES_ROOT}/codex/workspaces"
    "${AGENTIC_AGENT_WORKSPACES_ROOT}/opencode/workspaces"
    "${AGENTIC_AGENT_WORKSPACES_ROOT}/vibestral/workspaces"
    "${AGENTIC_ROOT}/shared-rw"
  )

  local dir
  for dir in "${readonly_dirs[@]}"; do
    ensure_dir "${dir}" 0750
  done

  for dir in "${writable_dirs[@]}"; do
    ensure_dir "${dir}" 0770
  done

  ensure_gate_mcp_token

  if [[ "${EUID}" -eq 0 ]]; then
    for dir in "${readonly_dirs[@]}"; do
      chown "root:${AGENT_RUNTIME_GID}" "${dir}"
    done
    for dir in "${writable_dirs[@]}"; do
      chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${dir}"
    done
  fi

  log "agents runtime initialized at ${AGENTIC_ROOT} with workspaces root ${AGENTIC_AGENT_WORKSPACES_ROOT} (uid=${AGENT_RUNTIME_UID}, gid=${AGENT_RUNTIME_GID})"
}

main "$@"
