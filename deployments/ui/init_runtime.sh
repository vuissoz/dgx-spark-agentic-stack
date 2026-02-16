#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
AGENT_RUNTIME_UID="${AGENT_RUNTIME_UID:-1000}"
AGENT_RUNTIME_GID="${AGENT_RUNTIME_GID:-1000}"
TEMPLATE_DIR="${REPO_ROOT}/examples/ui"

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

main() {
  install -d -m 0750 "${AGENTIC_ROOT}/openwebui"
  install -d -m 0750 "${AGENTIC_ROOT}/openwebui/config"
  install -d -m 0770 "${AGENTIC_ROOT}/openwebui/data"

  install -d -m 0750 "${AGENTIC_ROOT}/openhands"
  install -d -m 0750 "${AGENTIC_ROOT}/openhands/config"
  install -d -m 0770 "${AGENTIC_ROOT}/openhands/state"
  install -d -m 0770 "${AGENTIC_ROOT}/openhands/logs"
  install -d -m 0770 "${AGENTIC_ROOT}/openhands/workspaces"

  install -d -m 0750 "${AGENTIC_ROOT}/comfyui"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/models"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/input"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/output"
  install -d -m 0770 "${AGENTIC_ROOT}/comfyui/user"

  copy_if_missing "${TEMPLATE_DIR}/openwebui.env" "${AGENTIC_ROOT}/openwebui/config/openwebui.env" 0600
  copy_if_missing "${TEMPLATE_DIR}/openhands.env" "${AGENTIC_ROOT}/openhands/config/openhands.env" 0600

  chmod 0600 "${AGENTIC_ROOT}/openwebui/config/openwebui.env" "${AGENTIC_ROOT}/openhands/config/openhands.env"

  if [[ "${EUID}" -eq 0 ]]; then
    chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" \
      "${AGENTIC_ROOT}/openwebui/data" \
      "${AGENTIC_ROOT}/openhands/state" \
      "${AGENTIC_ROOT}/openhands/logs" \
      "${AGENTIC_ROOT}/openhands/workspaces" \
      "${AGENTIC_ROOT}/comfyui/models" \
      "${AGENTIC_ROOT}/comfyui/input" \
      "${AGENTIC_ROOT}/comfyui/output" \
      "${AGENTIC_ROOT}/comfyui/user"
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    chmod 0770 "${AGENTIC_ROOT}/openwebui/data" \
      "${AGENTIC_ROOT}/openhands/state" \
      "${AGENTIC_ROOT}/openhands/logs" \
      "${AGENTIC_ROOT}/openhands/workspaces" \
      "${AGENTIC_ROOT}/comfyui/models" \
      "${AGENTIC_ROOT}/comfyui/input" \
      "${AGENTIC_ROOT}/comfyui/output" \
      "${AGENTIC_ROOT}/comfyui/user"
    log "non-root runtime init: relaxed UI runtime dirs for userns compatibility"
  fi
}

main "$@"
