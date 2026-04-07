#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
AGENTIC_PROFILE="${AGENTIC_PROFILE:-strict-prod}"
if [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]]; then
  AGENTIC_AGENT_WORKSPACES_ROOT="${AGENTIC_AGENT_WORKSPACES_ROOT:-${AGENTIC_ROOT}/agent-workspaces}"
else
  AGENTIC_AGENT_WORKSPACES_ROOT="${AGENTIC_AGENT_WORKSPACES_ROOT:-${AGENTIC_ROOT}}"
fi
AGENTIC_CLAUDE_WORKSPACES_DIR="${AGENTIC_CLAUDE_WORKSPACES_DIR:-${AGENTIC_AGENT_WORKSPACES_ROOT}/claude/workspaces}"
AGENTIC_CODEX_WORKSPACES_DIR="${AGENTIC_CODEX_WORKSPACES_DIR:-${AGENTIC_AGENT_WORKSPACES_ROOT}/codex/workspaces}"
AGENTIC_OPENCODE_WORKSPACES_DIR="${AGENTIC_OPENCODE_WORKSPACES_DIR:-${AGENTIC_AGENT_WORKSPACES_ROOT}/opencode/workspaces}"
AGENTIC_VIBESTRAL_WORKSPACES_DIR="${AGENTIC_VIBESTRAL_WORKSPACES_DIR:-${AGENTIC_AGENT_WORKSPACES_ROOT}/vibestral/workspaces}"
AGENTIC_HERMES_WORKSPACES_DIR="${AGENTIC_HERMES_WORKSPACES_DIR:-${AGENTIC_AGENT_WORKSPACES_ROOT}/hermes/workspaces}"
AGENT_RUNTIME_UID="${AGENT_RUNTIME_UID:-1000}"
AGENT_RUNTIME_GID="${AGENT_RUNTIME_GID:-1000}"
WORKSPACE_SEED_DIR="${AGENTIC_WORKSPACE_SEED_DIR:-${REPO_ROOT}/examples/workspace-default-python}"

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

seed_workspace_if_missing() {
  local workspace_dir="$1"
  local seed_basename
  local destination

  [[ -d "${WORKSPACE_SEED_DIR}" ]] || {
    log "workspace seed skipped, source folder missing: ${WORKSPACE_SEED_DIR}"
    return 0
  }

  seed_basename="$(basename "${WORKSPACE_SEED_DIR}")"
  destination="${workspace_dir}/${seed_basename}"

  if [[ -e "${destination}" ]]; then
    log "preserve existing workspace seed: ${destination}"
    return 0
  fi

  cp -a "${WORKSPACE_SEED_DIR}" "${destination}"
  chmod -R u+rwX "${destination}" 2>/dev/null || true
  if [[ "${EUID}" -eq 0 ]]; then
    chown -R "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${destination}" || true
  fi
  log "seeded workspace folder: ${destination}"
}

main() {
  local -a readonly_dirs=(
    "${AGENTIC_ROOT}/claude"
    "${AGENTIC_ROOT}/codex"
    "${AGENTIC_ROOT}/opencode"
    "${AGENTIC_ROOT}/vibestral"
    "${AGENTIC_ROOT}/hermes"
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
    "${AGENTIC_ROOT}/hermes/state"
    "${AGENTIC_ROOT}/hermes/logs"
    "${AGENTIC_CLAUDE_WORKSPACES_DIR}"
    "${AGENTIC_CODEX_WORKSPACES_DIR}"
    "${AGENTIC_OPENCODE_WORKSPACES_DIR}"
    "${AGENTIC_VIBESTRAL_WORKSPACES_DIR}"
    "${AGENTIC_HERMES_WORKSPACES_DIR}"
    "${AGENTIC_ROOT}/shared-rw"
  )

  local dir
  for dir in "${readonly_dirs[@]}"; do
    ensure_dir "${dir}" 0750
  done

  for dir in "${writable_dirs[@]}"; do
    ensure_dir "${dir}" 0770
  done

  seed_workspace_if_missing "${AGENTIC_CLAUDE_WORKSPACES_DIR}"
  seed_workspace_if_missing "${AGENTIC_CODEX_WORKSPACES_DIR}"
  seed_workspace_if_missing "${AGENTIC_OPENCODE_WORKSPACES_DIR}"
  seed_workspace_if_missing "${AGENTIC_VIBESTRAL_WORKSPACES_DIR}"
  seed_workspace_if_missing "${AGENTIC_HERMES_WORKSPACES_DIR}"

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
