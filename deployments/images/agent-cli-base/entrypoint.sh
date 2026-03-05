#!/usr/bin/env bash
set -euo pipefail

tool="${AGENT_TOOL:-agent}"
session="${AGENT_SESSION:-${tool}}"
workspace="${AGENT_WORKSPACE:-/workspace}"
state_dir="${AGENT_STATE_DIR:-/state}"
logs_dir="${AGENT_LOGS_DIR:-/logs}"
agent_home="${AGENT_HOME:-${HOME:-${state_dir}/home}}"
agent_defaults_file="${AGENT_DEFAULTS_FILE:-${state_dir}/bootstrap/ollama-gate-defaults.env}"
default_model_fallback="qwen3-coder:30b"
default_context_window_fallback="262144"

export HOME="${agent_home}"
mkdir -p "${workspace}" "${state_dir}" "${logs_dir}" "${agent_home}" \
  "${agent_home}/.config" "${agent_home}/.cache" "${agent_home}/.codex" "${agent_home}/.vibe"
chmod 0700 "${agent_home}" "${agent_home}/.config" "${agent_home}/.cache" "${agent_home}/.codex" "${agent_home}/.vibe" 2>/dev/null || true
if [[ -n "${TMPDIR:-}" ]]; then
  mkdir -p "${TMPDIR}"
  chmod 0700 "${TMPDIR}" 2>/dev/null || true
fi

log() {
  printf '%s\n' "$*"
}

write_if_changed() {
  local target_path="$1"
  local source_path="$2"

  if [[ -f "${target_path}" ]] && cmp -s "${source_path}" "${target_path}"; then
    rm -f "${source_path}"
    return 0
  fi

  mv "${source_path}" "${target_path}"
}

bootstrap_shell_home() {
  local bash_profile="${agent_home}/.bash_profile"
  local bashrc="${agent_home}/.bashrc"
  local local_bin_line='export PATH="${HOME}/.local/bin:${PATH}"'

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
export PATH="${HOME}/.local/bin:${PATH}"
EOF
    chmod 0600 "${bashrc}" || true
  elif ! grep -Eq '/\.local/bin' "${bashrc}"; then
    printf '%s\n' "${local_bin_line}" >>"${bashrc}"
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
export AGENTIC_DEFAULT_MODEL="${AGENTIC_DEFAULT_MODEL:-qwen3-coder:30b}"
export AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW="${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-262144}"
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
  ensure_default_export "AGENTIC_DEFAULT_MODEL" '${AGENTIC_DEFAULT_MODEL:-qwen3-coder:30b}'
  ensure_default_export "AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW" '${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-262144}'
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

  local codex_bootstrap_dir="${state_dir}/bootstrap"
  local codex_catalog="${AGENT_CODEX_MODEL_CATALOG_FILE:-${codex_bootstrap_dir}/codex-model-catalog.json}"
  local codex_config="${agent_home}/.codex/config.toml"
  local default_model="${AGENTIC_DEFAULT_MODEL:-${default_model_fallback}}"
  local default_context_window="${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-${default_context_window_fallback}}"
  local gate_base_url="${AGENTIC_OLLAMA_GATE_BASE_URL:-http://ollama-gate:11435}"
  local codex_base_instructions
  local tmp_catalog
  local tmp_existing
  local tmp_filtered
  local tmp_config

  codex_base_instructions="$(cat <<'EOF'
You are Codex, a coding agent running in the Codex CLI on a user's machine.

Focus on practical software engineering work: understand the request, inspect the codebase, apply targeted changes, and verify outcomes.

Be concise, factual, and collaborative. Explain tradeoffs only when they matter.

Prefer safe, reversible actions. Avoid destructive operations unless explicitly requested.
EOF
)"

  mkdir -p "${codex_bootstrap_dir}"
  tmp_catalog="$(mktemp)"
  if ! [[ "${default_context_window}" =~ ^[0-9]+$ ]] || (( default_context_window < 2048 )); then
    default_context_window="${default_context_window_fallback}"
  fi

  python3 - "${default_model}" "${codex_base_instructions}" "${default_context_window}" >"${tmp_catalog}" <<'PY'
import json
import sys

model = sys.argv[1]
base_instructions = sys.argv[2]
context_window = int(sys.argv[3])

catalog = {
    "models": [
        {
            "slug": model,
            "display_name": model,
            "description": "Local Ollama model via ollama-gate",
            "default_reasoning_level": "medium",
            "supported_reasoning_levels": [
                {"effort": "low", "description": "Fast responses with lighter reasoning"},
                {"effort": "medium", "description": "Balanced speed and reasoning"},
                {"effort": "high", "description": "Deeper reasoning for complex tasks"},
            ],
            "shell_type": "shell_command",
            "visibility": "list",
            "supported_in_api": True,
            "priority": 1,
            "availability_nux": None,
            "upgrade": None,
            "base_instructions": base_instructions,
            "model_messages": None,
            "supports_reasoning_summaries": False,
            "default_reasoning_summary": "auto",
            "support_verbosity": False,
            "default_verbosity": None,
            "apply_patch_tool_type": "freeform",
            "truncation_policy": {"mode": "bytes", "limit": 10000},
            "supports_parallel_tool_calls": False,
            "context_window": context_window,
            "auto_compact_token_limit": None,
            "effective_context_window_percent": 95,
            "experimental_supported_tools": [],
            "input_modalities": ["text", "image"],
            "prefer_websockets": False,
        }
    ]
}

json.dump(catalog, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
  write_if_changed "${codex_catalog}" "${tmp_catalog}"
  chmod 0600 "${codex_catalog}" || true

  tmp_config="$(mktemp)"
  {
    cat <<EOF
# Managed by agent-entrypoint (codex local provider defaults)
model = "${default_model}"
model_provider = "ollama_gate"
model_catalog_json = "${codex_catalog}"

[model_providers.ollama_gate]
name = "ollama-gate"
base_url = "${gate_base_url}"
wire_api = "responses"
EOF
  } >"${tmp_config}"

  if [[ -f "${codex_config}" ]]; then
    tmp_existing="$(mktemp)"
    tmp_filtered="$(mktemp)"
    cp "${codex_config}" "${tmp_existing}"
    awk '
      BEGIN { in_provider_section = 0 }
      {
        if (in_provider_section == 1) {
          if ($0 ~ /^[[:space:]]*\[/) {
            in_provider_section = 0
          } else {
            next
          }
        }

        if ($0 ~ /^[[:space:]]*model[[:space:]]*=/) next
        if ($0 ~ /^[[:space:]]*model_provider[[:space:]]*=/) next
        if ($0 ~ /^[[:space:]]*model_catalog_json[[:space:]]*=/) next
        if ($0 ~ /^[[:space:]]*\[model_providers\.ollama_gate\][[:space:]]*$/) {
          in_provider_section = 1
          next
        }

        print
      }
    ' "${tmp_existing}" >"${tmp_filtered}"
    rm -f "${tmp_existing}"

    if [[ -s "${tmp_filtered}" ]]; then
      printf '\n' >>"${tmp_config}"
      cat "${tmp_filtered}" >>"${tmp_config}"
    fi
    rm -f "${tmp_filtered}"
  fi

  write_if_changed "${codex_config}" "${tmp_config}"
  chmod 0600 "${codex_config}" || true
  log "INFO: codex defaults config reconciled (${codex_config})"
  log "INFO: codex model catalog reconciled (${codex_catalog})"
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
name = "${AGENTIC_DEFAULT_MODEL:-${default_model_fallback}}"
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
