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
  "${agent_home}/.config" "${agent_home}/.cache" "${agent_home}/.codex" "${agent_home}/.vibe"
chmod 0700 "${agent_home}" "${agent_home}/.config" "${agent_home}/.cache" "${agent_home}/.codex" "${agent_home}/.vibe" 2>/dev/null || true

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
export AGENTIC_DEFAULT_MODEL="${AGENTIC_DEFAULT_MODEL:-llama3.1:8b}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-${AGENTIC_OLLAMA_GATE_BASE_URL}}"
export OPENAI_BASE_URL="${OPENAI_BASE_URL:-${AGENTIC_OLLAMA_GATE_V1_URL}}"
export OPENAI_API_BASE_URL="${OPENAI_API_BASE_URL:-${AGENTIC_OLLAMA_GATE_V1_URL}}"
export OPENAI_API_BASE="${OPENAI_API_BASE:-${AGENTIC_OLLAMA_GATE_V1_URL}}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-local-ollama}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-${AGENTIC_OLLAMA_GATE_BASE_URL}}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-local-ollama}"
export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-${AGENTIC_DEFAULT_MODEL}}"
EOF
    chmod 0600 "${agent_defaults_file}" || true
    log "INFO: created first-run defaults file (${agent_defaults_file})"
  fi

  ensure_default_export() {
    local key="$1"
    local expression="$2"
    if ! grep -Eq "^export[[:space:]]+${key}=" "${agent_defaults_file}"; then
      printf 'export %s="%s"\n' "${key}" "${expression}" >> "${agent_defaults_file}"
      log "INFO: added missing ${key} to ${agent_defaults_file}"
    fi
  }

  ensure_default_export "AGENTIC_OLLAMA_GATE_BASE_URL" '${AGENTIC_OLLAMA_GATE_BASE_URL:-http://ollama-gate:11435}'
  ensure_default_export "AGENTIC_OLLAMA_GATE_V1_URL" '${AGENTIC_OLLAMA_GATE_V1_URL:-${AGENTIC_OLLAMA_GATE_BASE_URL%/}/v1}'
  ensure_default_export "AGENTIC_DEFAULT_MODEL" '${AGENTIC_DEFAULT_MODEL:-llama3.1:8b}'
  ensure_default_export "OLLAMA_BASE_URL" '${OLLAMA_BASE_URL:-${AGENTIC_OLLAMA_GATE_BASE_URL}}'
  ensure_default_export "OPENAI_BASE_URL" '${OPENAI_BASE_URL:-${AGENTIC_OLLAMA_GATE_V1_URL}}'
  ensure_default_export "OPENAI_API_BASE_URL" '${OPENAI_API_BASE_URL:-${AGENTIC_OLLAMA_GATE_V1_URL}}'
  ensure_default_export "OPENAI_API_BASE" '${OPENAI_API_BASE:-${AGENTIC_OLLAMA_GATE_V1_URL}}'
  ensure_default_export "OPENAI_API_KEY" '${OPENAI_API_KEY:-local-ollama}'
  ensure_default_export "ANTHROPIC_BASE_URL" '${ANTHROPIC_BASE_URL:-${AGENTIC_OLLAMA_GATE_BASE_URL}}'
  ensure_default_export "ANTHROPIC_API_KEY" '${ANTHROPIC_API_KEY:-local-ollama}'
  ensure_default_export "ANTHROPIC_MODEL" '${ANTHROPIC_MODEL:-${AGENTIC_DEFAULT_MODEL}}'

  # Keep runtime environment aligned with persisted defaults for tmux sessions.
  # shellcheck disable=SC1090
  source "${agent_defaults_file}" || true
}

bootstrap_codex_config() {
  [[ "${tool}" == "codex" ]] || return 0

  local codex_config="${agent_home}/.codex/config.toml"
  if [[ -f "${codex_config}" ]]; then
    return 0
  fi

  cat >"${codex_config}" <<EOF
model = "${AGENTIC_DEFAULT_MODEL:-llama3.1:8b}"
model_provider = "ollama_gate"

[model_providers.ollama_gate]
name = "ollama-gate"
base_url = "${AGENTIC_OLLAMA_GATE_BASE_URL:-http://ollama-gate:11435}"
wire_api = "responses"
EOF
  chmod 0600 "${codex_config}" || true
  log "INFO: created codex defaults config (${codex_config})"
}

bootstrap_vibestral_config() {
  [[ "${tool}" == "vibestral" ]] || return 0

  local vibe_config="${agent_home}/.vibe/config.toml"
  write_vibestral_defaults() {
    cat >"${vibe_config}" <<EOF
active_model = "local-gate"
enable_telemetry = false
enable_update_checks = false
enable_auto_update = false

[[providers]]
name = "ollama-gate"
api_base = "${AGENTIC_OLLAMA_GATE_V1_URL:-http://ollama-gate:11435/v1}"
api_key_env_var = ""
api_style = "openai"
backend = "generic"
reasoning_field_name = "reasoning_content"
project_id = ""
region = ""

[[models]]
name = "${AGENTIC_DEFAULT_MODEL:-llama3.1:8b}"
provider = "ollama-gate"
alias = "local-gate"
temperature = 0.2
input_price = 0.0
output_price = 0.0
thinking = "off"
EOF
  }

  if [[ -f "${vibe_config}" ]]; then
    if grep -Eq '^active_model[[:space:]]*=[[:space:]]*"devstral-2"' "${vibe_config}" \
      && grep -Eq '^name[[:space:]]*=[[:space:]]*"mistral"' "${vibe_config}" \
      && grep -Eq '^name[[:space:]]*=[[:space:]]*"llamacpp"' "${vibe_config}" \
      && ! grep -Eq '^name[[:space:]]*=[[:space:]]*"ollama-gate"' "${vibe_config}"; then
      write_vibestral_defaults
      chmod 0600 "${vibe_config}" || true
      log "INFO: migrated stock vibestral config to ollama-gate defaults (${vibe_config})"
    fi
    return 0
  fi

  write_vibestral_defaults
  chmod 0600 "${vibe_config}" || true
  log "INFO: created vibestral defaults config (${vibe_config})"
}

maybe_setup_vibestral() {
  [[ "${tool}" == "vibestral" ]] || return 0

  local vibe_state_dir="${AGENT_VIBE_STATE_DIR:-${state_dir}/vibe}"
  local vibe_setup_marker="${AGENT_VIBE_SETUP_MARKER:-${vibe_state_dir}/.setup-complete}"
  local setup_timeout="${AGENT_VIBE_SETUP_TIMEOUT_SEC:-120}"
  local setup_log="${logs_dir}/vibe-setup.log"
  local run_setup="${AGENT_VIBE_RUN_SETUP:-0}"

  export VIBE_STATE_DIR="${vibe_state_dir}"
  mkdir -p "${vibe_state_dir}"

  if [[ -f "${vibe_setup_marker}" ]]; then
    return 0
  fi

  if ! command -v vibe >/dev/null 2>&1; then
    log "WARN: vibestral bootstrap skipped because 'vibe' command is missing"
    return 0
  fi

  bootstrap_vibestral_config

  if [[ "${run_setup}" != "1" ]]; then
    touch "${vibe_setup_marker}"
    log "INFO: vibestral bootstrap marked complete without interactive setup (${vibe_setup_marker})"
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
bootstrap_codex_config
bootstrap_vibestral_config

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
