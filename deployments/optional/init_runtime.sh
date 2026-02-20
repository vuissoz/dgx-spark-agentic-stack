#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
TEMPLATE_DIR="${REPO_ROOT}/examples/optional"

log() {
  echo "INFO: $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

copy_if_missing() {
  local src="$1"
  local dst="$2"
  local mode="$3"

  [[ -f "${src}" ]] || die "template not found: ${src}"
  if [[ -f "${dst}" ]]; then
    log "preserve existing runtime file: ${dst}"
    return 0
  fi

  install -D -m "${mode}" "${src}" "${dst}"
  log "created runtime file: ${dst}"
}

ensure_secret_mode() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    chmod 0600 "${file}"
  fi
}

main() {
  local runtime_uid="${AGENT_RUNTIME_UID:-1000}"
  local runtime_gid="${AGENT_RUNTIME_GID:-1000}"

  install -d -m 0750 "${AGENTIC_ROOT}/optional"
  install -d -m 0750 "${AGENTIC_ROOT}/optional/openclaw"
  install -d -m 0750 "${AGENTIC_ROOT}/optional/openclaw/config"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/openclaw/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/openclaw/logs"
  install -d -m 0750 "${AGENTIC_ROOT}/optional/openclaw/sandbox"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/openclaw/sandbox/state"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/mcp"
  install -d -m 0750 "${AGENTIC_ROOT}/optional/mcp/config"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/mcp/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/mcp/logs"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/pi-mono"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/pi-mono/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/pi-mono/logs"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/pi-mono/workspaces"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/goose"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/goose/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/goose/logs"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/goose/workspaces"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/portainer"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/portainer/data"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/portainer/logs"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  install -d -m 0750 "${AGENTIC_ROOT}/deployments/optional"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets/runtime"

  copy_if_missing "${TEMPLATE_DIR}/openclaw.dm_allowlist.txt" "${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt" 0640
  copy_if_missing "${TEMPLATE_DIR}/openclaw.tool_allowlist.txt" "${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt" 0640
  copy_if_missing "${TEMPLATE_DIR}/mcp.tool_allowlist.txt" "${AGENTIC_ROOT}/optional/mcp/config/tool_allowlist.txt" 0640
  copy_if_missing "${TEMPLATE_DIR}/activation.request.example" "${AGENTIC_ROOT}/deployments/optional/openclaw.request" 0640
  copy_if_missing "${TEMPLATE_DIR}/activation.request.example" "${AGENTIC_ROOT}/deployments/optional/mcp.request" 0640
  copy_if_missing "${TEMPLATE_DIR}/activation.request.example" "${AGENTIC_ROOT}/deployments/optional/pi-mono.request" 0640
  copy_if_missing "${TEMPLATE_DIR}/activation.request.example" "${AGENTIC_ROOT}/deployments/optional/goose.request" 0640
  copy_if_missing "${TEMPLATE_DIR}/activation.request.example" "${AGENTIC_ROOT}/deployments/optional/portainer.request" 0640

  chmod 0644 "${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt" \
    "${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt" \
    "${AGENTIC_ROOT}/optional/mcp/config/tool_allowlist.txt"

  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/openclaw.token"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/mcp.token"

  if [[ "${EUID}" -eq 0 ]]; then
    chown -R "${runtime_uid}:${runtime_gid}" \
      "${AGENTIC_ROOT}/optional/openclaw/state" \
      "${AGENTIC_ROOT}/optional/openclaw/sandbox/state" \
      "${AGENTIC_ROOT}/optional/openclaw/logs" \
      "${AGENTIC_ROOT}/optional/mcp/state" \
      "${AGENTIC_ROOT}/optional/mcp/logs" \
      "${AGENTIC_ROOT}/optional/pi-mono/state" \
      "${AGENTIC_ROOT}/optional/pi-mono/logs" \
      "${AGENTIC_ROOT}/optional/pi-mono/workspaces" \
      "${AGENTIC_ROOT}/optional/goose/state" \
      "${AGENTIC_ROOT}/optional/goose/logs" \
      "${AGENTIC_ROOT}/optional/goose/workspaces" \
      "${AGENTIC_ROOT}/optional/portainer/data" \
      "${AGENTIC_ROOT}/optional/portainer/logs"
    if [[ -f "${AGENTIC_ROOT}/secrets/runtime/openclaw.token" ]]; then
      chown "${runtime_uid}:${runtime_gid}" "${AGENTIC_ROOT}/secrets/runtime/openclaw.token"
    fi
    if [[ -f "${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret" ]]; then
      chown "${runtime_uid}:${runtime_gid}" "${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret"
    fi
    if [[ -f "${AGENTIC_ROOT}/secrets/runtime/mcp.token" ]]; then
      chown "${runtime_uid}:${runtime_gid}" "${AGENTIC_ROOT}/secrets/runtime/mcp.token"
    fi
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    chmod 0770 "${AGENTIC_ROOT}/optional/openclaw/state" \
      "${AGENTIC_ROOT}/optional/openclaw/sandbox/state" \
      "${AGENTIC_ROOT}/optional/openclaw/logs" \
      "${AGENTIC_ROOT}/optional/mcp/state" \
      "${AGENTIC_ROOT}/optional/mcp/logs" \
      "${AGENTIC_ROOT}/optional/pi-mono/state" \
      "${AGENTIC_ROOT}/optional/pi-mono/logs" \
      "${AGENTIC_ROOT}/optional/pi-mono/workspaces" \
      "${AGENTIC_ROOT}/optional/goose/state" \
      "${AGENTIC_ROOT}/optional/goose/logs" \
      "${AGENTIC_ROOT}/optional/goose/workspaces" \
      "${AGENTIC_ROOT}/optional/portainer/data" \
      "${AGENTIC_ROOT}/optional/portainer/logs"
    log "non-root runtime init: relaxed optional dirs permissions for userns compatibility"
  fi
}

main "$@"
