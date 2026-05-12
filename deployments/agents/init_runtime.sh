#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"
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

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ensure_dir() {
  local path="$1"
  local mode="$2"
  install -d -m "${mode}" "${path}"
  chmod "${mode}" "${path}"
}

random_secret_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
    return 0
  fi
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

ensure_secret_path_is_file() {
  local file="$1"
  local file_type

  if [[ -d "${file}" ]]; then
    if [[ -z "$(find "${file}" -mindepth 1 -print -quit 2>/dev/null || true)" ]]; then
      rmdir "${file}" || die "secret path must be a regular file, but empty placeholder directory could not be removed: ${file}"
      log "removed empty directory placeholder for secret file: ${file}"
    else
      die "secret path must be a regular file, found non-empty directory: ${file}"
    fi
  elif [[ -e "${file}" && ! -f "${file}" ]]; then
    file_type="$(stat -c '%F' "${file}" 2>/dev/null || printf 'non-regular path')"
    die "secret path must be a regular file, found ${file_type}: ${file}"
  fi
}

ensure_secret_file_if_missing() {
  local file="$1"
  local mode="${2:-0600}"

  ensure_secret_path_is_file "${file}"
  if [[ -f "${file}" ]]; then
    chmod "${mode}" "${file}" || true
    return 0
  fi

  umask 077
  random_secret_hex >"${file}"
  chmod "${mode}" "${file}" || true
  log "generated runtime secret: ${file}"
}

repair_rootless_agents_layout() {
  local target_uid="${AGENT_RUNTIME_UID:-$(id -u)}"
  local target_gid="${AGENT_RUNTIME_GID:-$(id -g)}"
  local needs_repair=0
  local dir
  local -a repair_dirs=(
    "${AGENTIC_ROOT}/claude"
    "${AGENTIC_ROOT}/claude/state"
    "${AGENTIC_ROOT}/codex"
    "${AGENTIC_ROOT}/codex/state"
    "${AGENTIC_ROOT}/opencode"
    "${AGENTIC_ROOT}/opencode/state"
    "${AGENTIC_ROOT}/kilocode"
    "${AGENTIC_ROOT}/kilocode/state"
    "${AGENTIC_ROOT}/kilocode/logs"
    "${AGENTIC_KILOCODE_WORKSPACES_DIR}"
    "${AGENTIC_ROOT}/vibestral"
    "${AGENTIC_ROOT}/vibestral/state"
    "${AGENTIC_ROOT}/hermes"
    "${AGENTIC_ROOT}/hermes/state"
    "${AGENTIC_ROOT}/secrets/ssh"
    "${AGENTIC_ROOT}/secrets/runtime/git-forge"
  )

  [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]] || return 0
  [[ "${EUID}" -ne 0 ]] || return 0
  [[ -d "${AGENTIC_ROOT}" ]] || return 0

  for dir in "${repair_dirs[@]}"; do
    [[ -e "${dir}" ]] || continue
    if [[ ! -w "${dir}" ]] || [[ -n "$(find "${dir}" -mindepth 0 ! -writable -print -quit 2>/dev/null || true)" ]]; then
      needs_repair=1
      break
    fi
  done
  [[ "${needs_repair}" -eq 1 ]] || return 0

  command -v docker >/dev/null 2>&1 \
    || die "docker command is required to repair legacy agent ownership in rootless-dev"

  docker run --rm \
    -v "${AGENTIC_ROOT}:/repair/root" \
    busybox:1.36.1 sh -lc "
      set -eu
      for path in \
        /repair/root/claude \
        /repair/root/claude/state \
        /repair/root/codex \
        /repair/root/codex/state \
        /repair/root/opencode \
        /repair/root/opencode/state \
        /repair/root/kilocode \
        /repair/root/kilocode/state \
        /repair/root/kilocode/logs \
        /repair/root/agent-workspaces/kilocode/workspaces \
        /repair/root/vibestral \
        /repair/root/vibestral/state \
        /repair/root/hermes \
        /repair/root/hermes/state \
        /repair/root/secrets/ssh \
        /repair/root/secrets/runtime/git-forge
      do
        [ -e \"\${path}\" ] || continue
        chown -R ${target_uid}:${target_gid} \"\${path}\"
      done
    " || die "failed to repair legacy agent ownership for rootless-dev runtime"

  log "repaired legacy agent ownership with containerized chown (uid=${target_uid} gid=${target_gid})"
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
  local -a agent_tools=(
    claude
    codex
    opencode
    kilocode
    vibestral
    hermes
  )
  local -a readonly_dirs=(
    "${AGENTIC_ROOT}/claude"
    "${AGENTIC_ROOT}/codex"
    "${AGENTIC_ROOT}/opencode"
    "${AGENTIC_ROOT}/kilocode"
    "${AGENTIC_ROOT}/vibestral"
    "${AGENTIC_ROOT}/hermes"
    "${AGENTIC_ROOT}/shared-ro"
  )

  local -a writable_dirs=(
    "${AGENTIC_ROOT}/claude/state"
    "${AGENTIC_ROOT}/claude/logs"
    "${AGENTIC_ROOT}/codex/state"
    "${AGENTIC_ROOT}/codex/state/home"
    "${AGENTIC_ROOT}/codex/logs"
    "${AGENTIC_ROOT}/opencode/state"
    "${AGENTIC_ROOT}/opencode/state/home"
    "${AGENTIC_ROOT}/opencode/logs"
    "${AGENTIC_ROOT}/kilocode/state"
    "${AGENTIC_ROOT}/kilocode/state/home"
    "${AGENTIC_ROOT}/kilocode/logs"
    "${AGENTIC_ROOT}/vibestral/state"
    "${AGENTIC_ROOT}/vibestral/state/home"
    "${AGENTIC_ROOT}/vibestral/logs"
    "${AGENTIC_ROOT}/hermes/state"
    "${AGENTIC_ROOT}/hermes/state/home"
    "${AGENTIC_ROOT}/hermes/logs"
    "${AGENTIC_ROOT}/claude/state/home"
    "${AGENTIC_CLAUDE_WORKSPACES_DIR}"
    "${AGENTIC_CODEX_WORKSPACES_DIR}"
    "${AGENTIC_OPENCODE_WORKSPACES_DIR}"
    "${AGENTIC_KILOCODE_WORKSPACES_DIR}"
    "${AGENTIC_VIBESTRAL_WORKSPACES_DIR}"
    "${AGENTIC_HERMES_WORKSPACES_DIR}"
    "${AGENTIC_ROOT}/shared-rw"
  )

  local dir
  local tool
  repair_rootless_agents_layout

  for dir in "${readonly_dirs[@]}"; do
    ensure_dir "${dir}" 0750
  done

  for dir in "${writable_dirs[@]}"; do
    ensure_dir "${dir}" 0770
  done

  for tool in "${agent_tools[@]}"; do
    ensure_dir "${AGENTIC_ROOT}/${tool}/state/home" 0700
  done

  seed_workspace_if_missing "${AGENTIC_CLAUDE_WORKSPACES_DIR}"
  seed_workspace_if_missing "${AGENTIC_CODEX_WORKSPACES_DIR}"
  seed_workspace_if_missing "${AGENTIC_OPENCODE_WORKSPACES_DIR}"
  seed_workspace_if_missing "${AGENTIC_KILOCODE_WORKSPACES_DIR}"
  seed_workspace_if_missing "${AGENTIC_VIBESTRAL_WORKSPACES_DIR}"
  seed_workspace_if_missing "${AGENTIC_HERMES_WORKSPACES_DIR}"

  ensure_gate_mcp_token
  ensure_dir "${AGENTIC_ROOT}/secrets/ssh" 0750
  ensure_dir "${AGENTIC_ROOT}/secrets/runtime" 0700
  ensure_dir "${AGENTIC_ROOT}/secrets/runtime/git-forge" 0750
  for tool in "${agent_tools[@]}"; do
    ensure_dir "${AGENTIC_ROOT}/secrets/ssh/${tool}" 0700
    ensure_secret_file_if_missing "${AGENTIC_ROOT}/secrets/runtime/git-forge/${tool}.password" 0640
  done

  if [[ "${EUID}" -eq 0 ]]; then
    for dir in "${readonly_dirs[@]}"; do
      chown "root:${AGENT_RUNTIME_GID}" "${dir}"
    done
    for dir in "${writable_dirs[@]}"; do
      chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${dir}"
    done
    for tool in "${agent_tools[@]}"; do
      chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${AGENTIC_ROOT}/${tool}/state/home"
      chown -R "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${AGENTIC_ROOT}/secrets/ssh/${tool}" || true
      chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${AGENTIC_ROOT}/secrets/runtime/git-forge/${tool}.password" || true
      chmod 0700 "${AGENTIC_ROOT}/secrets/ssh/${tool}" || true
      chmod 0640 "${AGENTIC_ROOT}/secrets/runtime/git-forge/${tool}.password" || true
    done
  fi

  log "agents runtime initialized at ${AGENTIC_ROOT} with workspaces root ${AGENTIC_AGENT_WORKSPACES_ROOT} (uid=${AGENT_RUNTIME_UID}, gid=${AGENT_RUNTIME_GID})"
}

main "$@"
