#!/usr/bin/env bash
set -euo pipefail

tool="${AGENT_TOOL:-agent}"
session="${AGENT_SESSION:-${tool}}"
workspace="${AGENT_WORKSPACE:-/workspace}"
state_dir="${AGENT_STATE_DIR:-/state}"
logs_dir="${AGENT_LOGS_DIR:-/logs}"
agent_home="${AGENT_HOME:-${HOME:-${state_dir}/home}}"
agent_defaults_file="${AGENT_DEFAULTS_FILE:-${state_dir}/bootstrap/ollama-gate-defaults.env}"

export HOME="${agent_home}"
mkdir -p "${workspace}" "${state_dir}" "${logs_dir}" "${agent_home}" \
  "${agent_home}/.config" "${agent_home}/.cache" "${agent_home}/.codex"
chmod 0700 "${agent_home}" "${agent_home}/.config" "${agent_home}/.cache" "${agent_home}/.codex" 2>/dev/null || true

log() {
  printf '%s\n' "$*"
}

bootstrap_shell_home() {
  local bash_profile="${agent_home}/.bash_profile"
  local bashrc="${agent_home}/.bashrc"

  if [[ ! -f "${bash_profile}" ]]; then
    cat >"${bash_profile}" <<'EOF'
if [ -f "${HOME}/.bashrc" ]; then
  . "${HOME}/.bashrc"
fi
EOF
    chmod 0600 "${bash_profile}" || true
  fi

  if [[ ! -f "${bashrc}" ]]; then
    cat >"${bashrc}" <<'EOF'
export PATH="${PATH}"
EOF
    chmod 0600 "${bashrc}" || true
  fi
}

bootstrap_ollama_gate_defaults() {
  local defaults_dir
  defaults_dir="$(dirname "${agent_defaults_file}")"
  mkdir -p "${defaults_dir}"

  if [[ ! -f "${agent_defaults_file}" ]]; then
    cat >"${agent_defaults_file}" <<'EOF'
# Generated on first run by agent-entrypoint to keep agent defaults persistent.
export AGENTIC_OLLAMA_GATE_BASE_URL="${AGENTIC_OLLAMA_GATE_BASE_URL:-http://ollama-gate:11435}"
export AGENTIC_OLLAMA_GATE_V1_URL="${AGENTIC_OLLAMA_GATE_V1_URL:-${AGENTIC_OLLAMA_GATE_BASE_URL%/}/v1}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-${AGENTIC_OLLAMA_GATE_BASE_URL}}"
export OPENAI_BASE_URL="${OPENAI_BASE_URL:-${AGENTIC_OLLAMA_GATE_V1_URL}}"
export OPENAI_API_BASE_URL="${OPENAI_API_BASE_URL:-${AGENTIC_OLLAMA_GATE_V1_URL}}"
export OPENAI_API_BASE="${OPENAI_API_BASE:-${AGENTIC_OLLAMA_GATE_V1_URL}}"
EOF
    chmod 0600 "${agent_defaults_file}" || true
    log "INFO: created first-run defaults file (${agent_defaults_file})"
  fi

  # Keep runtime environment aligned with persisted defaults for tmux sessions.
  # shellcheck disable=SC1090
  source "${agent_defaults_file}" || true
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

report_primary_cli() {
  local primary_cli="${AGENT_PRIMARY_CLI:-}"
  [[ -n "${primary_cli}" ]] || return 0

  if command -v "${primary_cli}" >/dev/null 2>&1; then
    log "INFO: primary CLI '${primary_cli}' is available"
  else
    log "WARN: primary CLI '${primary_cli}' is missing from PATH"
  fi
}

start_session() {
  tmux new-session -d -s "${session}" -c "${workspace}" \
    "bash -lc 'if [ -f \"${agent_defaults_file}\" ]; then source \"${agent_defaults_file}\"; fi; exec bash -l'"
}

report_primary_cli
bootstrap_shell_home
bootstrap_ollama_gate_defaults

if ! tmux has-session -t "${session}" 2>/dev/null; then
  start_session
fi

maybe_setup_vibestral

while true; do
  sleep 5
  if ! tmux has-session -t "${session}" 2>/dev/null; then
    start_session
  fi
done
