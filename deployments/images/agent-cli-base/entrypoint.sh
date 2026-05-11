#!/usr/bin/env bash
set -euo pipefail

tool="${AGENT_TOOL:-agent}"
session="${AGENT_SESSION:-${tool}}"
workspace="${AGENT_WORKSPACE:-/workspace}"
state_dir="${AGENT_STATE_DIR:-/state}"
logs_dir="${AGENT_LOGS_DIR:-/logs}"
agent_home="${AGENT_HOME:-${HOME:-${state_dir}/home}}"
agent_defaults_file="${AGENT_DEFAULTS_FILE:-${state_dir}/bootstrap/ollama-gate-defaults.env}"
default_model_fallback="nemotron-cascade-2:30b"
default_context_window_fallback="50909"

export HOME="${agent_home}"
mkdir -p "${workspace}" "${state_dir}" "${logs_dir}" "${agent_home}" \
  "${agent_home}/.config" "${agent_home}/.cache" "${agent_home}/.codex" "${agent_home}/.vibe" "${agent_home}/.hermes" "${agent_home}/.kilo"
chmod 0700 "${agent_home}" "${agent_home}/.config" "${agent_home}/.cache" "${agent_home}/.codex" "${agent_home}/.vibe" "${agent_home}/.hermes" "${agent_home}/.kilo" 2>/dev/null || true
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

preserve_yaml_without_top_level_sections() {
  local input_path="$1"
  local output_path="$2"
  local managed_csv="$3"

  python3 - "${input_path}" "${output_path}" "${managed_csv}" <<'PY'
import pathlib
import re
import sys

input_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
managed = {item for item in sys.argv[3].split(",") if item}

if not input_path.exists():
    output_path.write_text("", encoding="utf-8")
    raise SystemExit(0)

top_level_key = re.compile(r"^([A-Za-z0-9_-]+):(?:\s.*)?$")
skip = False
kept = []

for line in input_path.read_text(encoding="utf-8").splitlines(keepends=True):
    if line.startswith((" ", "\t")):
        if not skip:
            kept.append(line)
        continue

    match = top_level_key.match(line.rstrip("\n"))
    if match:
        skip = match.group(1) in managed
        if skip:
            continue

    if not skip:
        kept.append(line)

output_path.write_text("".join(kept), encoding="utf-8")
PY
}

agentic_context_effective_budget() {
  local candidate=0
  local budget=0

  for candidate in "$@"; do
    [[ "${candidate}" =~ ^[0-9]+$ ]] || continue
    (( candidate > 0 )) || continue
    if (( budget == 0 || candidate < budget )); then
      budget="${candidate}"
    fi
  done

  printf '%s\n' "${budget}"
}

derive_compaction_policy() {
  local requested_context="${1:-0}"
  local backend_context="${2:-0}"
  local soft_percent="${3:-75}"
  local danger_percent="${4:-90}"
  local budget=0
  local soft_tokens=0
  local danger_tokens=0

  if ! [[ "${soft_percent}" =~ ^[0-9]+$ ]] || (( soft_percent <= 0 || soft_percent >= 100 )); then
    soft_percent="75"
  fi
  if ! [[ "${danger_percent}" =~ ^[0-9]+$ ]] || (( danger_percent <= 0 || danger_percent >= 100 )); then
    danger_percent="90"
  fi
  if (( soft_percent >= danger_percent )); then
    soft_percent="75"
    danger_percent="90"
  fi

  budget="$(agentic_context_effective_budget "${requested_context}" "${backend_context}")"
  if ! [[ "${budget}" =~ ^[0-9]+$ ]] || (( budget < 2048 )); then
    budget="${requested_context}"
  fi
  if ! [[ "${budget}" =~ ^[0-9]+$ ]] || (( budget < 2048 )); then
    budget="${default_context_window_fallback}"
  fi

  soft_tokens="$(( budget * soft_percent / 100 ))"
  danger_tokens="$(( budget * danger_percent / 100 ))"
  if (( soft_tokens < 1 )); then
    soft_tokens=1
  elif (( soft_tokens >= budget )); then
    soft_tokens="$(( budget - 1 ))"
  fi
  if (( danger_tokens <= soft_tokens )); then
    danger_tokens="$(( soft_tokens + 1 ))"
  fi
  if (( danger_tokens >= budget )); then
    danger_tokens="$(( budget - 1 ))"
  fi
  if (( danger_tokens <= soft_tokens )); then
    soft_tokens="$(( budget - 2 ))"
    danger_tokens="$(( budget - 1 ))"
  fi

  printf 'context_budget_tokens=%s\n' "${budget}"
  printf 'soft_percent=%s\n' "${soft_percent}"
  printf 'danger_percent=%s\n' "${danger_percent}"
  printf 'soft_tokens=%s\n' "${soft_tokens}"
  printf 'danger_tokens=%s\n' "${danger_tokens}"
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
  local default_context_window="${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-${default_context_window_fallback}}"
  local backend_context_window="${OLLAMA_CONTEXT_LENGTH:-${default_context_window}}"
  local compaction_soft_percent="${AGENTIC_CONTEXT_COMPACTION_SOFT_PERCENT:-75}"
  local compaction_danger_percent="${AGENTIC_CONTEXT_COMPACTION_DANGER_PERCENT:-90}"
  local context_budget_tokens="${AGENTIC_CONTEXT_BUDGET_TOKENS:-}"
  local compaction_soft_tokens="${AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS:-}"
  local compaction_danger_tokens="${AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS:-}"

  if ! [[ "${default_context_window}" =~ ^[0-9]+$ ]] || (( default_context_window < 2048 )); then
    default_context_window="${default_context_window_fallback}"
  fi
  if ! [[ "${backend_context_window}" =~ ^[0-9]+$ ]] || (( backend_context_window < 2048 )); then
    backend_context_window="${default_context_window}"
  fi
  if ! [[ "${context_budget_tokens}" =~ ^[0-9]+$ ]] \
    || ! [[ "${compaction_soft_tokens}" =~ ^[0-9]+$ ]] \
    || ! [[ "${compaction_danger_tokens}" =~ ^[0-9]+$ ]]; then
    while IFS='=' read -r key value; do
      [[ -n "${key}" ]] || continue
      case "${key}" in
        context_budget_tokens) context_budget_tokens="${value}" ;;
        soft_percent) compaction_soft_percent="${value}" ;;
        danger_percent) compaction_danger_percent="${value}" ;;
        soft_tokens) compaction_soft_tokens="${value}" ;;
        danger_tokens) compaction_danger_tokens="${value}" ;;
        *) ;;
      esac
    done < <(
      derive_compaction_policy \
        "${default_context_window}" \
        "${backend_context_window}" \
        "${compaction_soft_percent}" \
        "${compaction_danger_percent}"
    )
  fi

  defaults_dir="$(dirname "${agent_defaults_file}")"
  mkdir -p "${defaults_dir}"

  if [[ ! -f "${agent_defaults_file}" ]]; then
    cat >"${agent_defaults_file}" <<'EOF'
# Generated on first run by agent-entrypoint to keep agent defaults persistent.
export AGENTIC_OLLAMA_GATE_BASE_URL="${AGENTIC_OLLAMA_GATE_BASE_URL:-http://ollama-gate:11435}"
export AGENTIC_OLLAMA_GATE_V1_URL="${AGENTIC_OLLAMA_GATE_V1_URL:-${AGENTIC_OLLAMA_GATE_BASE_URL%/}/v1}"
export AGENTIC_DEFAULT_MODEL="${AGENTIC_DEFAULT_MODEL:-nemotron-cascade-2:30b}"
export AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW="${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-50909}"
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW}}"
export AGENTIC_CONTEXT_COMPACTION_SOFT_PERCENT="${AGENTIC_CONTEXT_COMPACTION_SOFT_PERCENT:-75}"
export AGENTIC_CONTEXT_COMPACTION_DANGER_PERCENT="${AGENTIC_CONTEXT_COMPACTION_DANGER_PERCENT:-90}"
export AGENTIC_CONTEXT_BUDGET_TOKENS="${AGENTIC_CONTEXT_BUDGET_TOKENS:-50909}"
export AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS="${AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS:-38181}"
export AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS="${AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS:-45818}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-${AGENTIC_OLLAMA_GATE_BASE_URL}}"
export OPENAI_BASE_URL="${OPENAI_BASE_URL:-${AGENTIC_OLLAMA_GATE_V1_URL}}"
export OPENAI_API_BASE_URL="${OPENAI_API_BASE_URL:-${AGENTIC_OLLAMA_GATE_V1_URL}}"
export OPENAI_API_BASE="${OPENAI_API_BASE:-${AGENTIC_OLLAMA_GATE_V1_URL}}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-local-ollama}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-${AGENTIC_OLLAMA_GATE_BASE_URL}}"
export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-local-ollama}"
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
  ensure_default_export "AGENTIC_DEFAULT_MODEL" '${AGENTIC_DEFAULT_MODEL:-nemotron-cascade-2:30b}'
  ensure_default_export "AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW" '${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-50909}'
  ensure_default_export "OLLAMA_CONTEXT_LENGTH" '${OLLAMA_CONTEXT_LENGTH:-${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW}}'
  ensure_default_export "AGENTIC_CONTEXT_COMPACTION_SOFT_PERCENT" '${AGENTIC_CONTEXT_COMPACTION_SOFT_PERCENT:-75}'
  ensure_default_export "AGENTIC_CONTEXT_COMPACTION_DANGER_PERCENT" '${AGENTIC_CONTEXT_COMPACTION_DANGER_PERCENT:-90}'
  ensure_default_export "AGENTIC_CONTEXT_BUDGET_TOKENS" '${AGENTIC_CONTEXT_BUDGET_TOKENS:-50909}'
  ensure_default_export "AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS" '${AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS:-38181}'
  ensure_default_export "AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS" '${AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS:-45818}'
  ensure_default_export "OLLAMA_BASE_URL" '${OLLAMA_BASE_URL:-${AGENTIC_OLLAMA_GATE_BASE_URL}}'
  ensure_default_export "OPENAI_BASE_URL" '${OPENAI_BASE_URL:-${AGENTIC_OLLAMA_GATE_V1_URL}}'
  ensure_default_export "OPENAI_API_BASE_URL" '${OPENAI_API_BASE_URL:-${AGENTIC_OLLAMA_GATE_V1_URL}}'
  ensure_default_export "OPENAI_API_BASE" '${OPENAI_API_BASE:-${AGENTIC_OLLAMA_GATE_V1_URL}}'
  ensure_default_export "OPENAI_API_KEY" '${OPENAI_API_KEY:-local-ollama}'
  ensure_default_export "ANTHROPIC_BASE_URL" '${ANTHROPIC_BASE_URL:-${AGENTIC_OLLAMA_GATE_BASE_URL}}'
  ensure_default_export "ANTHROPIC_AUTH_TOKEN" '${ANTHROPIC_AUTH_TOKEN:-local-ollama}'
  ensure_default_export "ANTHROPIC_API_KEY" '${ANTHROPIC_API_KEY:-local-ollama}'
  ensure_default_export "ANTHROPIC_MODEL" '${ANTHROPIC_MODEL:-${AGENTIC_DEFAULT_MODEL}}'

  # Keep runtime environment aligned with persisted defaults for tmux sessions.
  # shellcheck disable=SC1090
  source "${agent_defaults_file}" || true
}

codex_auto_bypass_enabled() {
  case "${AGENTIC_CODEX_AUTO_BYPASS_SANDBOX:-1}" in
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
  esac
  return 0
}

codex_userns_probe() {
  if [[ -n "${AGENTIC_CODEX_SANDBOX_PROBE_CMD:-}" ]]; then
    bash -lc "${AGENTIC_CODEX_SANDBOX_PROBE_CMD}" >/dev/null 2>&1
    return $?
  fi
  command -v unshare >/dev/null 2>&1 || return 127
  timeout 2 sh -lc 'unshare -Ur true' >/dev/null 2>&1
}

bootstrap_codex_sandbox_status() {
  [[ "${tool}" == "codex" ]] || return 0

  local codex_bootstrap_dir="${state_dir}/bootstrap"
  local codex_status_file="${AGENT_CODEX_SANDBOX_STATUS_FILE:-${codex_bootstrap_dir}/codex-sandbox-status.env}"
  local tmp_status
  local sandbox_mode="native-userns"
  local probe_result="ok"
  local detail="native user namespace sandbox is available inside the container"
  local auto_bypass="disabled"
  local probe_rc=0

  mkdir -p "${codex_bootstrap_dir}"
  if codex_auto_bypass_enabled; then
    auto_bypass="enabled"
  fi

  set +e
  codex_userns_probe
  probe_rc=$?
  set -e

  if [[ "${probe_rc}" -eq 0 ]]; then
    sandbox_mode="native-userns"
    probe_result="ok"
    detail="native user namespace sandbox is available inside the container"
  else
    if [[ "${probe_rc}" -eq 127 ]]; then
      probe_result="unshare-missing"
      detail="'unshare' is unavailable in the container runtime"
    else
      probe_result="blocked"
      detail="native user namespace sandbox probe failed inside the container runtime"
    fi
    if [[ "${auto_bypass}" == "enabled" ]]; then
      sandbox_mode="outer-container-bypass"
    else
      sandbox_mode="hard-fail"
    fi
  fi

  tmp_status="$(mktemp)"
  cat >"${tmp_status}" <<EOF
# Generated by agent-entrypoint to expose the effective Codex sandbox posture.
export AGENTIC_CODEX_SANDBOX_MODE="${sandbox_mode}"
export AGENTIC_CODEX_SANDBOX_PROBE_RESULT="${probe_result}"
export AGENTIC_CODEX_AUTO_BYPASS_SANDBOX_EFFECTIVE="${auto_bypass}"
export AGENTIC_CODEX_SANDBOX_DETAIL="${detail}"
EOF
  write_if_changed "${codex_status_file}" "${tmp_status}"
  chmod 0600 "${codex_status_file}" || true

  case "${sandbox_mode}" in
    native-userns)
      log "INFO: codex sandbox status: native-userns (${detail})"
      ;;
    outer-container-bypass)
      log "WARN: codex sandbox status: outer-container-bypass (${detail}; Codex will rely on container confinement when sandboxing is requested)"
      ;;
    hard-fail)
      log "WARN: codex sandbox status: hard-fail (${detail}; disable this only if you intentionally want Codex to error instead of using the wrapper fallback)"
      ;;
  esac
}

bootstrap_codex_config() {
  [[ "${tool}" == "codex" ]] || return 0

  local codex_bootstrap_dir="${state_dir}/bootstrap"
  local codex_catalog="${AGENT_CODEX_MODEL_CATALOG_FILE:-${codex_bootstrap_dir}/codex-model-catalog.json}"
  local codex_config="${agent_home}/.codex/config.toml"
  local default_model="${AGENTIC_DEFAULT_MODEL:-${default_model_fallback}}"
  local default_context_window="${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-${default_context_window_fallback}}"
  local backend_context_window="${OLLAMA_CONTEXT_LENGTH:-${default_context_window}}"
  local compaction_soft_percent="${AGENTIC_CONTEXT_COMPACTION_SOFT_PERCENT:-75}"
  local compaction_danger_percent="${AGENTIC_CONTEXT_COMPACTION_DANGER_PERCENT:-90}"
  local context_budget_tokens="${AGENTIC_CONTEXT_BUDGET_TOKENS:-}"
  local compaction_soft_tokens="${AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS:-}"
  local compaction_danger_tokens="${AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS:-}"
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
  if ! [[ "${backend_context_window}" =~ ^[0-9]+$ ]] || (( backend_context_window < 2048 )); then
    backend_context_window="${default_context_window}"
  fi
  if ! [[ "${context_budget_tokens}" =~ ^[0-9]+$ ]] \
    || ! [[ "${compaction_soft_tokens}" =~ ^[0-9]+$ ]] \
    || ! [[ "${compaction_danger_tokens}" =~ ^[0-9]+$ ]]; then
    while IFS='=' read -r key value; do
      [[ -n "${key}" ]] || continue
      case "${key}" in
        context_budget_tokens) context_budget_tokens="${value}" ;;
        soft_percent) compaction_soft_percent="${value}" ;;
        danger_percent) compaction_danger_percent="${value}" ;;
        soft_tokens) compaction_soft_tokens="${value}" ;;
        danger_tokens) compaction_danger_tokens="${value}" ;;
        *) ;;
      esac
    done < <(
      derive_compaction_policy \
        "${default_context_window}" \
        "${backend_context_window}" \
        "${compaction_soft_percent}" \
        "${compaction_danger_percent}"
    )
  fi
  codex_base_instructions="${codex_base_instructions}

Start compacting or summarizing once the session approaches ${compaction_soft_tokens} tokens.
Treat ${compaction_danger_tokens} tokens as near-limit and reduce context before continuing."

  python3 - "${default_model}" "${codex_base_instructions}" "${default_context_window}" "${compaction_soft_tokens}" >"${tmp_catalog}" <<'PY'
import json
import sys

model = sys.argv[1]
base_instructions = sys.argv[2]
context_window = int(sys.argv[3])
auto_compact_token_limit = int(sys.argv[4])

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
            "auto_compact_token_limit": auto_compact_token_limit,
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
  local tmp_config

  mkdir -p "$(dirname "${vibe_config}")"
  tmp_config="$(mktemp)"
  cat >"${tmp_config}" <<EOF
active_model = "local-gate"
enable_telemetry = false
enable_update_checks = false
enable_auto_update = false

[[providers]]
name = "ollama-gate"
api_base = "${AGENTIC_OLLAMA_GATE_V1_URL:-http://ollama-gate:11435/v1}"
api_key_env_var = "OPENAI_API_KEY"
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
  write_if_changed "${vibe_config}" "${tmp_config}"
  chmod 0600 "${vibe_config}" || true
  log "INFO: vibestral defaults config reconciled (${vibe_config})"
}

bootstrap_hermes_config() {
  [[ "${tool}" == "hermes" ]] || return 0

  local hermes_home="${HERMES_HOME:-${AGENT_HERMES_HOME:-${agent_home}/.hermes}}"
  local hermes_config="${hermes_home}/config.yaml"
  local hermes_env="${hermes_home}/.env"
  local default_model="${AGENTIC_DEFAULT_MODEL:-${default_model_fallback}}"
  local gate_v1_url="${AGENTIC_OLLAMA_GATE_V1_URL:-http://ollama-gate:11435/v1}"
  local api_key="${OPENAI_API_KEY:-local-ollama}"
  local tmp_config
  local tmp_env
  local preserved_config
  local preserved_env

  export HERMES_HOME="${hermes_home}"
  mkdir -p "${hermes_home}" "${hermes_home}/cron" "${hermes_home}/sessions" "${hermes_home}/logs" "${hermes_home}/memories" "${hermes_home}/skills"
  chmod 0700 "${hermes_home}" "${hermes_home}/cron" "${hermes_home}/sessions" "${hermes_home}/logs" "${hermes_home}/memories" "${hermes_home}/skills" 2>/dev/null || true

  preserved_config="$(mktemp)"
  preserve_yaml_without_top_level_sections \
    "${hermes_config}" \
    "${preserved_config}" \
    "model,providers,custom_providers,toolsets,terminal,logging"

  tmp_config="$(mktemp)"
  cat >"${tmp_config}" <<EOF
model:
  default: "${default_model}"
  provider: custom
  base_url: "${gate_v1_url}"
toolsets:
  - hermes-cli
  - web
terminal:
  backend: local
  cwd: /workspace
  persistent_shell: true
logging:
  level: INFO
  max_size_mb: 5
  backup_count: 3
EOF
  if [[ -s "${preserved_config}" ]]; then
    printf '\n' >>"${tmp_config}"
    cat "${preserved_config}" >>"${tmp_config}"
  fi
  write_if_changed "${hermes_config}" "${tmp_config}"
  chmod 0600 "${hermes_config}" || true

  preserved_env="$(mktemp)"
  if [[ -f "${hermes_env}" ]]; then
    grep -Ev '^(OPENAI_API_KEY|OPENAI_BASE_URL)=' "${hermes_env}" >"${preserved_env}" || true
  else
    : >"${preserved_env}"
  fi

  tmp_env="$(mktemp)"
  cat >"${tmp_env}" <<EOF
OPENAI_API_KEY=${api_key}
EOF
  if [[ -s "${preserved_env}" ]]; then
    printf '\n' >>"${tmp_env}"
    cat "${preserved_env}" >>"${tmp_env}"
  fi
  write_if_changed "${hermes_env}" "${tmp_env}"
  chmod 0600 "${hermes_env}" || true

  log "INFO: hermes defaults config reconciled (${hermes_config})"
}

bootstrap_opencode_config() {
  [[ "${tool}" == "opencode" ]] || return 0

  local opencode_config="${agent_home}/.config/opencode/opencode.json"
  local tmp_config
  local default_model="${AGENTIC_DEFAULT_MODEL:-${default_model_fallback}}"
  local gate_v1_url="${AGENTIC_OLLAMA_GATE_V1_URL:-http://ollama-gate:11435/v1}"

  mkdir -p "$(dirname "${opencode_config}")"
  tmp_config="$(mktemp)"
  python3 - "${opencode_config}" "${default_model}" "${gate_v1_url}" >"${tmp_config}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
default_model = sys.argv[2]
gate_v1_url = sys.argv[3]

base = {}
if config_path.exists():
    try:
      with config_path.open("r", encoding="utf-8") as fh:
        payload = json.load(fh)
      if isinstance(payload, dict):
        base = payload
    except Exception:
      base = {}

providers = base.get("provider")
if not isinstance(providers, dict):
    providers = {}

ollama_provider = providers.get("ollama")
if not isinstance(ollama_provider, dict):
    ollama_provider = {}

options = ollama_provider.get("options")
if not isinstance(options, dict):
    options = {}
options["baseURL"] = gate_v1_url

models = ollama_provider.get("models")
if not isinstance(models, dict):
    models = {}
models[default_model] = {"name": default_model}

ollama_provider["npm"] = "@ai-sdk/openai-compatible"
ollama_provider["name"] = "Ollama (agentic stack)"
ollama_provider["options"] = options
ollama_provider["models"] = models
providers["ollama"] = ollama_provider

base["$schema"] = "https://opencode.ai/config.json"
base["provider"] = providers
base["model"] = f"ollama/{default_model}"
base["small_model"] = f"ollama/{default_model}"

json.dump(base, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
  write_if_changed "${opencode_config}" "${tmp_config}"
  chmod 0600 "${opencode_config}" || true
  log "INFO: opencode defaults config reconciled (${opencode_config})"
}

bootstrap_kilocode_config() {
  [[ "${tool}" == "kilocode" ]] || return 0

  local kilocode_config="${agent_home}/.config/kilo/opencode.json"
  local tmp_config
  local default_model="${AGENTIC_DEFAULT_MODEL:-${default_model_fallback}}"
  local gate_v1_url="${AGENTIC_OLLAMA_GATE_V1_URL:-http://ollama-gate:11435/v1}"

  mkdir -p "$(dirname "${kilocode_config}")"
  tmp_config="$(mktemp)"
  python3 - "${kilocode_config}" "${default_model}" "${gate_v1_url}" >"${tmp_config}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
default_model = sys.argv[2]
gate_v1_url = sys.argv[3]

base = {}
if config_path.exists():
    try:
        with config_path.open("r", encoding="utf-8") as fh:
            payload = json.load(fh)
        if isinstance(payload, dict):
            base = payload
    except Exception:
        base = {}

providers = base.get("provider")
if not isinstance(providers, dict):
    providers = {}

ollama_provider = providers.get("ollama")
if not isinstance(ollama_provider, dict):
    ollama_provider = {}

options = ollama_provider.get("options")
if not isinstance(options, dict):
    options = {}
options["baseURL"] = gate_v1_url

models = ollama_provider.get("models")
if not isinstance(models, dict):
    models = {}
models[default_model] = {"name": default_model}

ollama_provider["npm"] = "@ai-sdk/openai-compatible"
ollama_provider["name"] = "Ollama (agentic stack)"
ollama_provider["options"] = options
ollama_provider["models"] = models
providers["ollama"] = ollama_provider

base["$schema"] = "https://app.kilo.ai/config.json"
base["provider"] = providers
base["model"] = f"ollama/{default_model}"
base["small_model"] = f"ollama/{default_model}"

json.dump(base, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
  write_if_changed "${kilocode_config}" "${tmp_config}"
  chmod 0600 "${kilocode_config}" || true
  log "INFO: kilocode defaults config reconciled (${kilocode_config})"
}

bootstrap_pi_config() {
  [[ "${tool}" == "pi-mono" || "${AGENT_PRIMARY_CLI:-}" == "pi" ]] || return 0

  local pi_config_dir="${agent_home}/.pi/agent"
  local pi_models_config="${pi_config_dir}/models.json"
  local pi_settings_config="${pi_config_dir}/settings.json"
  local default_model="${AGENTIC_DEFAULT_MODEL:-${default_model_fallback}}"
  local gate_v1_url="${AGENTIC_OLLAMA_GATE_V1_URL:-http://ollama-gate:11435/v1}"
  local provider_name="${AGENTIC_PI_PROVIDER_NAME:-ollama}"
  local provider_api_key="${AGENTIC_PI_API_KEY:-${OPENAI_API_KEY:-ollama}}"
  local tmp_models
  local tmp_settings

  mkdir -p "${pi_config_dir}"

  tmp_models="$(mktemp)"
  python3 - "${pi_models_config}" "${default_model}" "${gate_v1_url}" "${provider_name}" "${provider_api_key}" >"${tmp_models}" <<'PY'
import json
import pathlib
import sys

models_path = pathlib.Path(sys.argv[1])
default_model = sys.argv[2]
gate_v1_url = sys.argv[3]
provider_name = sys.argv[4]
provider_api_key = sys.argv[5]

payload = {}
if models_path.exists():
    try:
        with models_path.open("r", encoding="utf-8") as fh:
            parsed = json.load(fh)
        if isinstance(parsed, dict):
            payload = parsed
    except Exception:
        payload = {}

providers = payload.get("providers")
if not isinstance(providers, dict):
    providers = {}

provider = providers.get(provider_name)
if not isinstance(provider, dict):
    provider = {}

raw_models = provider.get("models")
normalized_models = []
has_default_model = False
if isinstance(raw_models, list):
    for model in raw_models:
        if not isinstance(model, dict):
            continue
        model_id = model.get("id")
        if not isinstance(model_id, str):
            continue
        model_id = model_id.strip()
        if not model_id:
            continue
        normalized_models.append({"id": model_id})
        if model_id == default_model:
            has_default_model = True

if not has_default_model:
    normalized_models.insert(0, {"id": default_model})

provider["baseUrl"] = gate_v1_url.rstrip("/")
provider["api"] = "openai-completions"
provider["apiKey"] = provider_api_key
provider["models"] = normalized_models
providers[provider_name] = provider
payload["providers"] = providers

json.dump(payload, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
  write_if_changed "${pi_models_config}" "${tmp_models}"
  chmod 0600 "${pi_models_config}" || true

  tmp_settings="$(mktemp)"
  python3 - "${pi_settings_config}" "${default_model}" "${provider_name}" >"${tmp_settings}" <<'PY'
import json
import pathlib
import sys

settings_path = pathlib.Path(sys.argv[1])
default_model = sys.argv[2]
provider_name = sys.argv[3]

payload = {}
if settings_path.exists():
    try:
        with settings_path.open("r", encoding="utf-8") as fh:
            parsed = json.load(fh)
        if isinstance(parsed, dict):
            payload = parsed
    except Exception:
        payload = {}

payload["defaultProvider"] = provider_name
payload["defaultModel"] = default_model

json.dump(payload, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
  write_if_changed "${pi_settings_config}" "${tmp_settings}"
  chmod 0600 "${pi_settings_config}" || true
  log "INFO: pi defaults config reconciled (${pi_config_dir})"
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
bootstrap_codex_sandbox_status
bootstrap_codex_config
bootstrap_opencode_config
bootstrap_kilocode_config
bootstrap_pi_config
bootstrap_vibestral_config
bootstrap_hermes_config

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
