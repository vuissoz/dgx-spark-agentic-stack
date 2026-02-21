#!/usr/bin/env bash
set -euo pipefail

tool="${AGENT_TOOL:-agent}"
session="${AGENT_SESSION:-${tool}}"
workspace="${AGENT_WORKSPACE:-/workspace}"
state_dir="${AGENT_STATE_DIR:-/state}"
logs_dir="${AGENT_LOGS_DIR:-/logs}"

mkdir -p "${workspace}" "${state_dir}" "${logs_dir}"

log() {
  printf '%s\n' "$*"
}

maybe_setup_vibestral() {
  [[ "${tool}" == "vibestral" ]] || return 0

  local vibe_state_dir="${AGENT_VIBE_STATE_DIR:-${state_dir}/vibe}"
  local vibe_setup_marker="${AGENT_VIBE_SETUP_MARKER:-${vibe_state_dir}/.setup-complete}"
  local setup_timeout="${AGENT_VIBE_SETUP_TIMEOUT_SEC:-120}"
  local setup_log="${logs_dir}/vibe-setup.log"

  export VIBE_STATE_DIR="${vibe_state_dir}"
  mkdir -p "${vibe_state_dir}"

  if [[ -f "${vibe_setup_marker}" ]]; then
    return 0
  fi

  if ! command -v vibe >/dev/null 2>&1; then
    log "WARN: vibestral bootstrap skipped because 'vibe' command is missing"
    return 0
  fi

  set +e
  timeout "${setup_timeout}" vibe --setup >"${setup_log}" 2>&1
  local rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    touch "${vibe_setup_marker}"
    log "INFO: vibestral bootstrap complete (${vibe_setup_marker})"
  else
    log "WARN: vibestral bootstrap failed (exit=${rc}); see ${setup_log}"
  fi
}

start_session() {
  tmux new-session -d -s "${session}" -c "${workspace}" "bash -lc 'exec bash -l'"
}

maybe_setup_vibestral

if ! tmux has-session -t "${session}" 2>/dev/null; then
  start_session
fi

while true; do
  sleep 5
  if ! tmux has-session -t "${session}" 2>/dev/null; then
    start_session
  fi
done
