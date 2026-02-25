#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

profile_override=""
root_override=""
compose_project_override=""
network_override=""
egress_network_override=""
ollama_models_override=""
default_model_override=""
grafana_admin_user_override=""
grafana_admin_password_override=""
limits_default_cpus_override=""
limits_default_mem_override=""
limits_core_cpus_override=""
limits_core_mem_override=""
limits_agents_cpus_override=""
limits_agents_mem_override=""
limits_ui_cpus_override=""
limits_ui_mem_override=""
limits_obs_cpus_override=""
limits_obs_mem_override=""
limits_rag_cpus_override=""
limits_rag_mem_override=""
limits_optional_cpus_override=""
limits_optional_mem_override=""

openwebui_admin_email_override=""
openwebui_admin_password_override=""
openwebui_secret_key_override=""
openwebui_allow_model_pull_override=""
openhands_llm_model_override=""
openhands_llm_api_key_override=""
allowlist_domains_override=""
openai_api_key_override=""
openrouter_api_key_override=""
optional_modules_override=""
openclaw_token_override=""
openclaw_webhook_secret_override=""
mcp_token_override=""

skip_ui_bootstrap=0
skip_network_bootstrap=0
skip_secret_bootstrap=0
require_complete=0
non_interactive=0
output_file="${AGENTIC_ONBOARD_OUTPUT:-${AGENTIC_REPO_ROOT}/.runtime/env.generated.sh}"

summary_generated_files=()
summary_deferred=()
summary_blockers=()
summary_modules=()

usage() {
  cat <<'USAGE'
Usage:
  deployments/bootstrap/onboarding_env.sh [options]

Runtime options:
  --profile <strict-prod|rootless-dev>
  --root <path>
  --compose-project <name>
  --network <name>
  --egress-network <name>
  --ollama-models-dir <path>
  --default-model <name>
  --grafana-admin-user <name>
  --grafana-admin-password <password>
  --limits-default-cpus <cores>
  --limits-default-mem <size>
  --limits-core-cpus <cores>
  --limits-core-mem <size>
  --limits-agents-cpus <cores>
  --limits-agents-mem <size>
  --limits-ui-cpus <cores>
  --limits-ui-mem <size>
  --limits-obs-cpus <cores>
  --limits-obs-mem <size>
  --limits-rag-cpus <cores>
  --limits-rag-mem <size>
  --limits-optional-cpus <cores>
  --limits-optional-mem <size>

First-run bootstrap options:
  --openwebui-admin-email <email>
  --openwebui-admin-password <password>
  --openwebui-secret-key <value>
  --openwebui-allow-model-pull <true|false>
  --openhands-llm-model <name>
  --openhands-llm-api-key <key>
  --allowlist-domains <csv>
  --openai-api-key <key>
  --openrouter-api-key <key>
  --optional-modules <csv>
  --openclaw-token <token>
  --openclaw-webhook-secret <secret>
  --mcp-token <token>
  --skip-ui-bootstrap
  --skip-network-bootstrap
  --skip-secret-bootstrap

General options:
  --output <path>
  --non-interactive
  --require-complete
  -h, --help
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

info() {
  echo "INFO: $*"
}

section() {
  echo
  echo "=== $* ==="
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"
}

trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

summary_add_generated() {
  summary_generated_files+=("$1")
}

summary_add_deferred() {
  summary_deferred+=("$1")
}

summary_add_blocker() {
  summary_blockers+=("$1")
}

summary_add_module() {
  local module="$1"
  local existing
  for existing in "${summary_modules[@]:-}"; do
    [[ "${existing}" == "${module}" ]] && return 0
  done
  summary_modules+=("${module}")
}

default_root_for_profile() {
  local profile="$1"
  if [[ "${profile}" == "rootless-dev" ]]; then
    printf '%s\n' "${HOME}/.local/share/agentic"
  else
    printf '%s\n' "/srv/agentic"
  fi
}

default_compose_project_for_profile() {
  local profile="$1"
  if [[ "${profile}" == "rootless-dev" ]]; then
    printf '%s\n' "agentic-dev"
  else
    printf '%s\n' "agentic"
  fi
}

default_network_for_profile() {
  local profile="$1"
  if [[ "${profile}" == "rootless-dev" ]]; then
    printf '%s\n' "agentic-dev"
  else
    printf '%s\n' "agentic"
  fi
}

default_egress_network_for_profile() {
  local profile="$1"
  if [[ "${profile}" == "rootless-dev" ]]; then
    printf '%s\n' "agentic-dev-egress"
  else
    printf '%s\n' "agentic-egress"
  fi
}

default_ollama_models_for_profile() {
  local profile="$1"
  local root_path="$2"
  if [[ "${profile}" == "rootless-dev" ]]; then
    printf '%s\n' "${HOME}/wkdir/open-webui/ollama_data/models"
  else
    printf '%s\n' "${root_path}/ollama/models"
  fi
}

default_ollama_tmp_for_models_dir() {
  local models_dir="$1"
  if [[ "$(basename "${models_dir}")" == "models" ]]; then
    printf '%s\n' "$(dirname "${models_dir}")/tmp"
    return 0
  fi
  printf '%s\n' ""
}

default_limits_default_cpus_for_profile() {
  local profile="$1"
  if [[ "${profile}" == "rootless-dev" ]]; then
    printf '%s\n' "0.75"
  else
    printf '%s\n' "1.00"
  fi
}

default_limits_default_mem_for_profile() {
  local profile="$1"
  if [[ "${profile}" == "rootless-dev" ]]; then
    printf '%s\n' "1g"
  else
    printf '%s\n' "1g"
  fi
}

default_limits_stack_cpus_for_profile() {
  local profile="$1"
  local stack="$2"
  if [[ "${profile}" == "rootless-dev" ]]; then
    case "${stack}" in
      core) printf '%s\n' "1.00" ;;
      agents) printf '%s\n' "0.75" ;;
      ui) printf '%s\n' "0.75" ;;
      obs) printf '%s\n' "0.50" ;;
      rag) printf '%s\n' "0.75" ;;
      optional) printf '%s\n' "0.50" ;;
      *) return 1 ;;
    esac
  else
    case "${stack}" in
      core) printf '%s\n' "1.50" ;;
      agents) printf '%s\n' "1.00" ;;
      ui) printf '%s\n' "1.00" ;;
      obs) printf '%s\n' "0.75" ;;
      rag) printf '%s\n' "1.00" ;;
      optional) printf '%s\n' "0.75" ;;
      *) return 1 ;;
    esac
  fi
}

default_limits_stack_mem_for_profile() {
  local profile="$1"
  local stack="$2"
  if [[ "${profile}" == "rootless-dev" ]]; then
    case "${stack}" in
      core) printf '%s\n' "2g" ;;
      agents) printf '%s\n' "1g" ;;
      ui) printf '%s\n' "1g" ;;
      obs) printf '%s\n' "512m" ;;
      rag) printf '%s\n' "1g" ;;
      optional) printf '%s\n' "512m" ;;
      *) return 1 ;;
    esac
  else
    case "${stack}" in
      core) printf '%s\n' "3g" ;;
      agents) printf '%s\n' "2g" ;;
      ui) printf '%s\n' "2g" ;;
      obs) printf '%s\n' "1g" ;;
      rag) printf '%s\n' "2g" ;;
      optional) printf '%s\n' "1g" ;;
      *) return 1 ;;
    esac
  fi
}

validate_profile() {
  case "$1" in
    strict-prod|rootless-dev) return 0 ;;
    *) return 1 ;;
  esac
}

validate_cpu_limit_value() {
  local key="$1"
  local value="$2"
  [[ -n "${value}" ]] || {
    echo "${key} cannot be empty" >&2
    return 1
  }
  [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    echo "${key} must be a positive CPU value (example: 0.75, 1, 2.5)" >&2
    return 1
  }
  awk -v value="${value}" 'BEGIN { exit !(value+0 > 0) }' || {
    echo "${key} must be > 0" >&2
    return 1
  }
}

validate_memory_limit_value() {
  local key="$1"
  local value="$2"
  [[ -n "${value}" ]] || {
    echo "${key} cannot be empty" >&2
    return 1
  }
  [[ "${value}" =~ ^[0-9]+([.][0-9]+)?[bBkKmMgG]$ ]] || {
    echo "${key} must use docker memory format (example: 512m, 1g, 2G)" >&2
    return 1
  }
}

validate_compose_or_network_name() {
  local key="$1"
  local value="$2"
  [[ -n "${value}" ]] || {
    echo "${key} cannot be empty" >&2
    return 1
  }
  [[ "${value}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || {
    echo "${key} must match [a-zA-Z0-9][a-zA-Z0-9_.-]*" >&2
    return 1
  }
}

validate_model_id_value() {
  local key="$1"
  local value="$2"
  [[ -n "${value}" ]] || {
    echo "${key} cannot be empty" >&2
    return 1
  }
  [[ "${value}" != *$'\n'* ]] || {
    echo "${key} must be a single-line model id" >&2
    return 1
  }
  [[ "${value}" != *[[:space:]]* ]] || {
    echo "${key} must not contain spaces" >&2
    return 1
  }
  return 0
}

validate_non_empty_single_line_value() {
  local key="$1"
  local value="$2"
  [[ -n "${value}" ]] || {
    echo "${key} cannot be empty" >&2
    return 1
  }
  [[ "${value}" != *$'\n'* ]] || {
    echo "${key} must be a single-line value" >&2
    return 1
  }
}

validate_path_value() {
  local profile="$1"
  local key="$2"
  local value="$3"
  local parent=""

  [[ -n "${value}" ]] || {
    echo "${key} cannot be empty" >&2
    return 1
  }
  [[ "${value}" != *$'\n'* ]] || {
    echo "${key} must be a single-line path" >&2
    return 1
  }
  [[ "${value}" == /* ]] || {
    echo "${key} must be an absolute path (start with /)" >&2
    return 1
  }
  [[ "${value}" != *[[:space:]]* ]] || {
    echo "${key} should not include spaces" >&2
    return 1
  }

  if [[ -e "${value}" ]]; then
    [[ -d "${value}" ]] || {
      echo "${key} exists but is not a directory: ${value}" >&2
      return 1
    }
    return 0
  fi

  parent="${value}"
  while [[ "${parent}" != "/" && ! -d "${parent}" ]]; do
    parent="$(dirname "${parent}")"
  done

  if [[ -w "${parent}" ]]; then
    return 0
  fi

  if [[ "${profile}" == "strict-prod" ]]; then
    warn "${key} parent '${parent}' is not writable for current user; this is acceptable in strict-prod when setup is run with sudo later."
    return 0
  fi

  echo "${key} is not creatable from current user context (parent not writable: ${parent}). Choose another path or fix permissions." >&2
  return 1
}

validate_email_value() {
  local key="$1"
  local value="$2"
  [[ -n "${value}" ]] || {
    echo "${key} cannot be empty" >&2
    return 1
  }
  [[ "${value}" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || {
    echo "${key} must look like an email address" >&2
    return 1
  }
}

validate_true_false_value() {
  local key="$1"
  local value="$2"
  case "${value,,}" in
    true|false|yes|no|1|0) return 0 ;;
    *)
      echo "${key} must be one of: true,false,yes,no,1,0" >&2
      return 1
      ;;
  esac
}

normalize_true_false_env_value() {
  local value="$1"
  case "${value,,}" in
    true|yes|1) printf '%s\n' "True" ;;
    false|no|0) printf '%s\n' "False" ;;
    *) return 1 ;;
  esac
}

normalize_openhands_model() {
  local model="$1"
  if [[ "${model}" == */* ]]; then
    printf '%s\n' "${model}"
  else
    printf 'openai/%s\n' "${model}"
  fi
}

render_openhands_settings_json() {
  local model="$1"
  local api_key="$2"
  local base_url="$3"

  python3 - "${model}" "${api_key}" "${base_url}" <<'PY'
import json
import sys

llm_model, llm_api_key, llm_base_url = sys.argv[1:4]
payload = {
    "language": "en",
    "agent": "CodeActAgent",
    "llm_model": llm_model,
    "llm_api_key": llm_api_key,
    "llm_base_url": llm_base_url,
    "v1_enabled": True,
}
sys.stdout.write(json.dumps(payload, separators=(",", ":")))
sys.stdout.write("\n")
PY
}

validate_allowlist_entry() {
  local entry="$1"
  [[ -n "${entry}" ]] || return 1
  if [[ "${entry}" =~ ^\.?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    return 0
  fi
  if [[ "${entry}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]]; then
    return 0
  fi
  return 1
}

normalize_allowlist_csv() {
  local raw="$1"
  printf '%s\n' "${raw}" \
    | tr ',' '\n' \
    | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | awk 'NF { if (!seen[$0]++) print $0 }'
}

default_allowlist_csv() {
  local template_path="${REPO_ROOT}/examples/core/allowlist.txt"

  if [[ ! -r "${template_path}" ]]; then
    printf '%s\n' "example.com,api.openai.com,openrouter.ai"
    return 0
  fi

  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { print }
  ' "${template_path}" | paste -sd, -
}

validate_allowlist_csv() {
  local raw="$1"
  local line
  local has_values=0

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    has_values=1
    validate_allowlist_entry "${line}" || {
      echo "allowlist entry is invalid: ${line}" >&2
      return 1
    }
  done < <(normalize_allowlist_csv "${raw}")

  [[ "${has_values}" -eq 1 ]] || {
    echo "allowlist cannot be empty" >&2
    return 1
  }
}

validate_optional_modules_csv() {
  local raw="$1"
  local entry
  local normalized
  local saw_none=0
  local saw_module=0

  normalized="$(normalize_allowlist_csv "${raw}" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${normalized}" ]]; then
    return 0
  fi

  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    case "${entry}" in
      none)
        saw_none=1
        ;;
      openclaw|mcp|pi-mono|goose|portainer)
        saw_module=1
        ;;
      *)
        echo "unknown optional module '${entry}' (allowed: openclaw,mcp,pi-mono,goose,portainer,none)" >&2
        return 1
        ;;
    esac
  done <<<"${normalized}"

  if [[ "${saw_none}" -eq 1 && "${saw_module}" -eq 1 ]]; then
    echo "optional modules value 'none' cannot be combined with other modules" >&2
    return 1
  fi
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local value=""

  printf '%s [%s]: ' "${prompt}" "${default_value}" >&2
  IFS= read -r value || die "input aborted"
  if [[ -z "${value}" ]]; then
    value="${default_value}"
  fi
  printf '%s\n' "${value}"
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="$2"
  local hint=""
  local value=""

  case "${default_answer}" in
    yes) hint="[Y/n]" ;;
    no) hint="[y/N]" ;;
    *) die "prompt_yes_no invalid default '${default_answer}'" ;;
  esac

  while true; do
    printf '%s %s: ' "${prompt}" "${hint}" >&2
    IFS= read -r value || die "input aborted"
    value="$(trim "${value}")"
    value="${value,,}"
    if [[ -z "${value}" ]]; then
      [[ "${default_answer}" == "yes" ]] && return 0 || return 1
    fi

    case "${value}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer yes or no." >&2 ;;
    esac
  done
}

prompt_secret_with_default() {
  local prompt="$1"
  local default_value="$2"
  local value=""

  if [[ -t 0 ]]; then
    printf '%s [hidden] (Enter keeps default): ' "${prompt}" >&2
    IFS= read -r -s value || die "input aborted"
    echo >&2
  else
    printf '%s [hidden] (Enter keeps default): ' "${prompt}" >&2
    IFS= read -r value || die "input aborted"
  fi

  if [[ -z "${value}" ]]; then
    value="${default_value}"
  fi
  printf '%s\n' "${value}"
}

prompt_secret_or_generate() {
  local prompt="$1"
  local value=""

  if [[ -t 0 ]]; then
    printf '%s [hidden] (Enter to auto-generate): ' "${prompt}" >&2
    IFS= read -r -s value || die "input aborted"
    echo >&2
  else
    printf '%s [hidden] (Enter to auto-generate): ' "${prompt}" >&2
    IFS= read -r value || die "input aborted"
  fi

  printf '%s\n' "${value}"
}

prompt_password_with_default() {
  local prompt="$1"
  local default_value="$2"
  local value=""
  local confirmation=""

  while true; do
    if [[ -t 0 ]]; then
      printf '%s [hidden] (Enter keeps default): ' "${prompt}" >&2
      IFS= read -r -s value || die "input aborted"
      echo >&2
    else
      printf '%s [hidden] (Enter keeps default): ' "${prompt}" >&2
      IFS= read -r value || die "input aborted"
    fi

    if [[ -z "${value}" ]]; then
      printf '%s\n' "${default_value}"
      return 0
    fi

    if [[ -t 0 ]]; then
      printf 'Confirm %s [hidden]: ' "${prompt}" >&2
      IFS= read -r -s confirmation || die "input aborted"
      echo >&2
    else
      printf 'Confirm %s [hidden]: ' "${prompt}" >&2
      IFS= read -r confirmation || die "input aborted"
    fi

    if [[ "${value}" == "${confirmation}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi

    echo "Values do not match. Please try again." >&2
  done
}

prompt_password_or_generate() {
  local prompt="$1"
  local value=""
  local confirmation=""

  while true; do
    if [[ -t 0 ]]; then
      printf '%s [hidden] (Enter to auto-generate): ' "${prompt}" >&2
      IFS= read -r -s value || die "input aborted"
      echo >&2
    else
      printf '%s [hidden] (Enter to auto-generate): ' "${prompt}" >&2
      IFS= read -r value || die "input aborted"
    fi

    if [[ -z "${value}" ]]; then
      printf '\n'
      return 0
    fi

    if [[ -t 0 ]]; then
      printf 'Confirm %s [hidden]: ' "${prompt}" >&2
      IFS= read -r -s confirmation || die "input aborted"
      echo >&2
    else
      printf 'Confirm %s [hidden]: ' "${prompt}" >&2
      IFS= read -r confirmation || die "input aborted"
    fi

    if [[ "${value}" == "${confirmation}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi

    echo "Values do not match. Please try again." >&2
  done
}

normalize_output_path() {
  if [[ "${output_file}" != /* ]]; then
    output_file="${AGENTIC_REPO_ROOT}/${output_file}"
  fi
}

path_parent_writable_or_exists() {
  local path="$1"
  local parent

  if [[ -d "${path}" ]]; then
    [[ -w "${path}" ]]
    return $?
  fi

  parent="${path}"
  while [[ "${parent}" != "/" && ! -d "${parent}" ]]; do
    parent="$(dirname "${parent}")"
  done
  [[ -w "${parent}" ]]
}

runtime_root_writable() {
  local root_path="$1"
  local candidates=(
    "${root_path}"
    "${root_path}/openwebui"
    "${root_path}/proxy"
    "${root_path}/secrets"
  )
  local path

  for path in "${candidates[@]}"; do
    if path_parent_writable_or_exists "${path}"; then
      return 0
    fi
  done
  return 1
}

write_file_atomic() {
  local destination="$1"
  local mode="$2"
  local content="$3"
  local parent
  local tmp_file

  parent="$(dirname "${destination}")"
  install -d -m 0750 "${parent}" || return 1

  tmp_file="$(mktemp "${destination}.tmp.XXXXXX")" || return 1
  printf '%s' "${content}" >"${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }
  chmod "${mode}" "${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }
  mv "${tmp_file}" "${destination}" || {
    rm -f "${tmp_file}"
    return 1
  }
  return 0
}

upsert_export_in_file() {
  local file_path="$1"
  local key="$2"
  local value="$3"
  local quoted
  local tmp_file

  [[ -f "${file_path}" ]] || return 1
  quoted="$(shell_quote "${value}")"
  tmp_file="$(mktemp "${file_path}.tmp.XXXXXX")" || return 1

  awk -v k="${key}" -v q="${quoted}" '
    BEGIN { replaced=0 }
    $0 ~ ("^export " k "=") {
      print "export " k "=" q
      replaced=1
      next
    }
    { print }
    END {
      if (!replaced) {
        print "export " k "=" q
      }
    }
  ' "${file_path}" >"${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }

  chmod 0640 "${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }
  mv "${tmp_file}" "${file_path}" || {
    rm -f "${tmp_file}"
    return 1
  }
  return 0
}

upsert_key_value_in_file() {
  local file_path="$1"
  local key="$2"
  local value="$3"
  local mode="${4:-0640}"
  local tmp_file

  [[ -f "${file_path}" ]] || return 1
  tmp_file="$(mktemp "${file_path}.tmp.XXXXXX")" || return 1

  awk -v k="${key}" -v v="${value}" '
    BEGIN { replaced=0 }
    $0 ~ ("^" k "=") {
      if (!replaced) {
        print k "=" v
        replaced=1
      }
      next
    }
    { print }
    END {
      if (!replaced) {
        print k "=" v
      }
    }
  ' "${file_path}" >"${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }

  chmod "${mode}" "${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }
  mv "${tmp_file}" "${file_path}" || {
    rm -f "${tmp_file}"
    return 1
  }
  return 0
}

optional_request_default_need() {
  local module="$1"
  case "${module}" in
    openclaw) printf '%s\n' "Enable scoped OpenClaw webhook and DM automation for approved workflows." ;;
    mcp) printf '%s\n' "Expose a restricted MCP catalog for local automation workflows." ;;
    pi-mono) printf '%s\n' "Provide an additional isolated CLI agent runtime for targeted tasks." ;;
    goose) printf '%s\n' "Provide an isolated Goose CLI runtime for approved workflows." ;;
    portainer) printf '%s\n' "Provide temporary loopback-only Portainer visibility for local diagnostics." ;;
    *) return 1 ;;
  esac
}

optional_request_default_success() {
  local module="$1"
  case "${module}" in
    openclaw) printf '%s\n' "Webhook auth succeeds, deny paths stay blocked, and service healthcheck stays green." ;;
    mcp) printf '%s\n' "Only allowlisted tools are available and service healthcheck stays green." ;;
    pi-mono) printf '%s\n' "Container starts with expected user/workspace mappings and no forbidden mounts." ;;
    goose) printf '%s\n' "Container starts successfully with isolated workspace and expected proxy controls." ;;
    portainer) printf '%s\n' "UI is reachable on loopback only and runs without docker.sock mount." ;;
    *) return 1 ;;
  esac
}

ensure_optional_request_file() {
  local root_path="$1"
  local module="$2"
  local request_path="${root_path}/deployments/optional/${module}.request"
  local need_value
  local success_value
  local owner_value
  local created=0
  local changed=0
  local request_content

  need_value="$(optional_request_default_need "${module}")" || {
    summary_add_blocker "unable to resolve request defaults for optional module ${module}"
    return 1
  }
  success_value="$(optional_request_default_success "${module}")" || {
    summary_add_blocker "unable to resolve success defaults for optional module ${module}"
    return 1
  }
  owner_value="${SUDO_USER:-${USER:-operator}}"

  if [[ ! -f "${request_path}" ]]; then
    request_content="need=${need_value}
success=${success_value}
owner=${owner_value}
expires_at=
"
    if ! write_file_atomic "${request_path}" 0640 "${request_content}"; then
      summary_add_blocker "failed to write ${request_path}"
      return 1
    fi
    created=1
  fi

  if ! grep -Eq '^need=[^[:space:]].+$' "${request_path}"; then
    if ! upsert_key_value_in_file "${request_path}" "need" "${need_value}" 0640; then
      summary_add_blocker "failed to update need= in ${request_path}"
      return 1
    fi
    changed=1
  fi

  if ! grep -Eq '^success=[^[:space:]].+$' "${request_path}"; then
    if ! upsert_key_value_in_file "${request_path}" "success" "${success_value}" 0640; then
      summary_add_blocker "failed to update success= in ${request_path}"
      return 1
    fi
    changed=1
  fi

  if ! grep -Eq '^owner=' "${request_path}"; then
    if ! upsert_key_value_in_file "${request_path}" "owner" "${owner_value}" 0640; then
      summary_add_blocker "failed to update owner= in ${request_path}"
      return 1
    fi
    changed=1
  fi

  if ! grep -Eq '^expires_at=' "${request_path}"; then
    if ! upsert_key_value_in_file "${request_path}" "expires_at" "" 0640; then
      summary_add_blocker "failed to update expires_at= in ${request_path}"
      return 1
    fi
    changed=1
  fi

  if [[ "${created}" -eq 1 || "${changed}" -eq 1 ]]; then
    summary_add_generated "${request_path}"
  fi
  return 0
}

write_secret_file() {
  local root_path="$1"
  local file_name="$2"
  local value="$3"
  local destination="${root_path}/secrets/runtime/${file_name}"

  if [[ -z "${value}" ]]; then
    return 0
  fi

  if ! write_file_atomic "${destination}" 0600 "${value}"$'\n'; then
    summary_add_blocker "unable to write secret file ${destination}; re-run onboarding with writable permissions or sudo"
    return 1
  fi

  summary_add_generated "${destination}"
  return 0
}

generate_secret_value() {
  local bytes="${1:-24}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "${bytes}"
  else
    head -c "${bytes}" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

write_env_file() {
  local profile="$1"
  local root_path="$2"
  local compose_project="$3"
  local network="$4"
  local egress_network="$5"
  local ollama_models="$6"
  local default_model="$7"
  local grafana_admin_user="$8"
  local grafana_admin_password="$9"
  local limits_default_cpus="${10}"
  local limits_default_mem="${11}"
  local limits_core_cpus="${12}"
  local limits_core_mem="${13}"
  local limits_agents_cpus="${14}"
  local limits_agents_mem="${15}"
  local limits_ui_cpus="${16}"
  local limits_ui_mem="${17}"
  local limits_obs_cpus="${18}"
  local limits_obs_mem="${19}"
  local limits_rag_cpus="${20}"
  local limits_rag_mem="${21}"
  local limits_optional_cpus="${22}"
  local limits_optional_mem="${23}"
  local out_file="${24}"
  local tmp_file=""

  install -d -m 0750 "$(dirname "${out_file}")"
  tmp_file="$(mktemp "${out_file}.tmp.XXXXXX")"

  cat >"${tmp_file}" <<EOF_ENV
#!/usr/bin/env bash
# Generated by deployments/bootstrap/onboarding_env.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Source this file in your shell to set runtime variables.
export AGENTIC_PROFILE=$(shell_quote "${profile}")
export AGENTIC_ROOT=$(shell_quote "${root_path}")
export AGENTIC_COMPOSE_PROJECT=$(shell_quote "${compose_project}")
export AGENTIC_NETWORK=$(shell_quote "${network}")
export AGENTIC_EGRESS_NETWORK=$(shell_quote "${egress_network}")
export AGENTIC_DOCKER_USER_SOURCE_NETWORKS=$(shell_quote "${network},${egress_network}")
export OLLAMA_MODELS_DIR=$(shell_quote "${ollama_models}")
export AGENTIC_DEFAULT_MODEL=$(shell_quote "${default_model}")
export OLLAMA_PRELOAD_GENERATE_MODEL=$(shell_quote "${default_model}")
export GRAFANA_ADMIN_USER=$(shell_quote "${grafana_admin_user}")
export GRAFANA_ADMIN_PASSWORD=$(shell_quote "${grafana_admin_password}")
export AGENTIC_OLLAMA_GATE_BASE_URL='http://ollama-gate:11435'
export AGENTIC_OLLAMA_GATE_V1_URL='http://ollama-gate:11435/v1'
export ANTHROPIC_BASE_URL='http://ollama-gate:11435'
export ANTHROPIC_API_KEY='local-ollama'
export ANTHROPIC_MODEL=$(shell_quote "${default_model}")
export AGENTIC_AGENT_NO_NEW_PRIVILEGES='false'
export AGENTIC_LIMIT_DEFAULT_CPUS=$(shell_quote "${limits_default_cpus}")
export AGENTIC_LIMIT_DEFAULT_MEM=$(shell_quote "${limits_default_mem}")
export AGENTIC_LIMIT_CORE_CPUS=$(shell_quote "${limits_core_cpus}")
export AGENTIC_LIMIT_CORE_MEM=$(shell_quote "${limits_core_mem}")
export AGENTIC_LIMIT_AGENTS_CPUS=$(shell_quote "${limits_agents_cpus}")
export AGENTIC_LIMIT_AGENTS_MEM=$(shell_quote "${limits_agents_mem}")
export AGENTIC_LIMIT_UI_CPUS=$(shell_quote "${limits_ui_cpus}")
export AGENTIC_LIMIT_UI_MEM=$(shell_quote "${limits_ui_mem}")
export AGENTIC_LIMIT_OBS_CPUS=$(shell_quote "${limits_obs_cpus}")
export AGENTIC_LIMIT_OBS_MEM=$(shell_quote "${limits_obs_mem}")
export AGENTIC_LIMIT_RAG_CPUS=$(shell_quote "${limits_rag_cpus}")
export AGENTIC_LIMIT_RAG_MEM=$(shell_quote "${limits_rag_mem}")
export AGENTIC_LIMIT_OPTIONAL_CPUS=$(shell_quote "${limits_optional_cpus}")
export AGENTIC_LIMIT_OPTIONAL_MEM=$(shell_quote "${limits_optional_mem}")
EOF_ENV

  mv "${tmp_file}" "${out_file}"
  chmod 0640 "${out_file}"
}

collect_text_value() {
  local -n out_ref="$1"
  local key="$2"
  local default_value="$3"
  local override_value="$4"
  local validator_func="$5"
  local info_text="$6"

  out_ref="${override_value:-${default_value}}"
  if [[ "${non_interactive}" -eq 0 && -z "${override_value}" ]]; then
    [[ -n "${info_text}" ]] && info "${info_text}"
    while true; do
      candidate="$(prompt_with_default "${key}" "${out_ref}")"
      if "${validator_func}" "${key}" "${candidate}"; then
        out_ref="${candidate}"
        break
      fi
    done
  else
    "${validator_func}" "${key}" "${out_ref}" || die "invalid ${key}"
  fi
}

collect_path_value() {
  local -n out_ref="$1"
  local key="$2"
  local profile="$3"
  local default_value="$4"
  local override_value="$5"
  local info_text="$6"

  out_ref="${override_value:-${default_value}}"
  if [[ "${non_interactive}" -eq 0 && -z "${override_value}" ]]; then
    [[ -n "${info_text}" ]] && info "${info_text}"
    while true; do
      candidate="$(prompt_with_default "${key}" "${out_ref}")"
      if validate_path_value "${profile}" "${key}" "${candidate}"; then
        out_ref="${candidate}"
        break
      fi
    done
  else
    validate_path_value "${profile}" "${key}" "${out_ref}" || die "invalid ${key}"
  fi
}

collect_cpu_limit() {
  local -n out_ref="$1"
  local key="$2"
  local default_value="$3"
  local override_value="$4"
  local info_text="$5"

  out_ref="${override_value:-${default_value}}"
  if [[ "${non_interactive}" -eq 0 && -z "${override_value}" ]]; then
    [[ -n "${info_text}" ]] && info "${info_text}"
    while true; do
      candidate="$(prompt_with_default "${key}" "${out_ref}")"
      if validate_cpu_limit_value "${key}" "${candidate}"; then
        out_ref="${candidate}"
        break
      fi
    done
  else
    validate_cpu_limit_value "${key}" "${out_ref}" || die "invalid ${key}"
  fi
}

collect_mem_limit() {
  local -n out_ref="$1"
  local key="$2"
  local default_value="$3"
  local override_value="$4"

  out_ref="${override_value:-${default_value}}"
  if [[ "${non_interactive}" -eq 0 && -z "${override_value}" ]]; then
    while true; do
      candidate="$(prompt_with_default "${key}" "${out_ref}")"
      if validate_memory_limit_value "${key}" "${candidate}"; then
        out_ref="${candidate}"
        break
      fi
    done
  else
    validate_memory_limit_value "${key}" "${out_ref}" || die "invalid ${key}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || die "missing value for --profile"
      profile_override="$2"
      shift 2
      ;;
    --root)
      [[ $# -ge 2 ]] || die "missing value for --root"
      root_override="$2"
      shift 2
      ;;
    --compose-project)
      [[ $# -ge 2 ]] || die "missing value for --compose-project"
      compose_project_override="$2"
      shift 2
      ;;
    --network)
      [[ $# -ge 2 ]] || die "missing value for --network"
      network_override="$2"
      shift 2
      ;;
    --egress-network)
      [[ $# -ge 2 ]] || die "missing value for --egress-network"
      egress_network_override="$2"
      shift 2
      ;;
    --ollama-models-dir)
      [[ $# -ge 2 ]] || die "missing value for --ollama-models-dir"
      ollama_models_override="$2"
      shift 2
      ;;
    --default-model)
      [[ $# -ge 2 ]] || die "missing value for --default-model"
      default_model_override="$2"
      shift 2
      ;;
    --grafana-admin-user)
      [[ $# -ge 2 ]] || die "missing value for --grafana-admin-user"
      grafana_admin_user_override="$2"
      shift 2
      ;;
    --grafana-admin-password)
      [[ $# -ge 2 ]] || die "missing value for --grafana-admin-password"
      grafana_admin_password_override="$2"
      shift 2
      ;;
    --limits-default-cpus)
      [[ $# -ge 2 ]] || die "missing value for --limits-default-cpus"
      limits_default_cpus_override="$2"
      shift 2
      ;;
    --limits-default-mem)
      [[ $# -ge 2 ]] || die "missing value for --limits-default-mem"
      limits_default_mem_override="$2"
      shift 2
      ;;
    --limits-core-cpus)
      [[ $# -ge 2 ]] || die "missing value for --limits-core-cpus"
      limits_core_cpus_override="$2"
      shift 2
      ;;
    --limits-core-mem)
      [[ $# -ge 2 ]] || die "missing value for --limits-core-mem"
      limits_core_mem_override="$2"
      shift 2
      ;;
    --limits-agents-cpus)
      [[ $# -ge 2 ]] || die "missing value for --limits-agents-cpus"
      limits_agents_cpus_override="$2"
      shift 2
      ;;
    --limits-agents-mem)
      [[ $# -ge 2 ]] || die "missing value for --limits-agents-mem"
      limits_agents_mem_override="$2"
      shift 2
      ;;
    --limits-ui-cpus)
      [[ $# -ge 2 ]] || die "missing value for --limits-ui-cpus"
      limits_ui_cpus_override="$2"
      shift 2
      ;;
    --limits-ui-mem)
      [[ $# -ge 2 ]] || die "missing value for --limits-ui-mem"
      limits_ui_mem_override="$2"
      shift 2
      ;;
    --limits-obs-cpus)
      [[ $# -ge 2 ]] || die "missing value for --limits-obs-cpus"
      limits_obs_cpus_override="$2"
      shift 2
      ;;
    --limits-obs-mem)
      [[ $# -ge 2 ]] || die "missing value for --limits-obs-mem"
      limits_obs_mem_override="$2"
      shift 2
      ;;
    --limits-rag-cpus)
      [[ $# -ge 2 ]] || die "missing value for --limits-rag-cpus"
      limits_rag_cpus_override="$2"
      shift 2
      ;;
    --limits-rag-mem)
      [[ $# -ge 2 ]] || die "missing value for --limits-rag-mem"
      limits_rag_mem_override="$2"
      shift 2
      ;;
    --limits-optional-cpus)
      [[ $# -ge 2 ]] || die "missing value for --limits-optional-cpus"
      limits_optional_cpus_override="$2"
      shift 2
      ;;
    --limits-optional-mem)
      [[ $# -ge 2 ]] || die "missing value for --limits-optional-mem"
      limits_optional_mem_override="$2"
      shift 2
      ;;
    --openwebui-admin-email)
      [[ $# -ge 2 ]] || die "missing value for --openwebui-admin-email"
      openwebui_admin_email_override="$2"
      shift 2
      ;;
    --openwebui-admin-password)
      [[ $# -ge 2 ]] || die "missing value for --openwebui-admin-password"
      openwebui_admin_password_override="$2"
      shift 2
      ;;
    --openwebui-secret-key)
      [[ $# -ge 2 ]] || die "missing value for --openwebui-secret-key"
      openwebui_secret_key_override="$2"
      shift 2
      ;;
    --openwebui-allow-model-pull)
      [[ $# -ge 2 ]] || die "missing value for --openwebui-allow-model-pull"
      openwebui_allow_model_pull_override="$2"
      shift 2
      ;;
    --openhands-llm-model)
      [[ $# -ge 2 ]] || die "missing value for --openhands-llm-model"
      openhands_llm_model_override="$2"
      shift 2
      ;;
    --openhands-llm-api-key)
      [[ $# -ge 2 ]] || die "missing value for --openhands-llm-api-key"
      openhands_llm_api_key_override="$2"
      shift 2
      ;;
    --allowlist-domains)
      [[ $# -ge 2 ]] || die "missing value for --allowlist-domains"
      allowlist_domains_override="$2"
      shift 2
      ;;
    --openai-api-key)
      [[ $# -ge 2 ]] || die "missing value for --openai-api-key"
      openai_api_key_override="$2"
      shift 2
      ;;
    --openrouter-api-key)
      [[ $# -ge 2 ]] || die "missing value for --openrouter-api-key"
      openrouter_api_key_override="$2"
      shift 2
      ;;
    --optional-modules)
      [[ $# -ge 2 ]] || die "missing value for --optional-modules"
      optional_modules_override="$2"
      shift 2
      ;;
    --openclaw-token)
      [[ $# -ge 2 ]] || die "missing value for --openclaw-token"
      openclaw_token_override="$2"
      shift 2
      ;;
    --openclaw-webhook-secret)
      [[ $# -ge 2 ]] || die "missing value for --openclaw-webhook-secret"
      openclaw_webhook_secret_override="$2"
      shift 2
      ;;
    --mcp-token)
      [[ $# -ge 2 ]] || die "missing value for --mcp-token"
      mcp_token_override="$2"
      shift 2
      ;;
    --skip-ui-bootstrap)
      skip_ui_bootstrap=1
      shift
      ;;
    --skip-network-bootstrap)
      skip_network_bootstrap=1
      shift
      ;;
    --skip-secret-bootstrap)
      skip_secret_bootstrap=1
      shift
      ;;
    --output)
      [[ $# -ge 2 ]] || die "missing value for --output"
      output_file="$2"
      shift 2
      ;;
    --non-interactive)
      non_interactive=1
      shift
      ;;
    --require-complete)
      require_complete=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

normalize_output_path

section "Section 1/4: Runtime Profile and Paths"

profile="${profile_override:-${AGENTIC_PROFILE}}"
if [[ "${non_interactive}" -eq 0 && -z "${profile_override}" ]]; then
  info "AGENTIC_PROFILE controls host mode: strict-prod (CDC target) or rootless-dev (local non-root dev)."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_PROFILE (strict-prod or rootless-dev)" "${profile}")"
    if validate_profile "${candidate}"; then
      profile="${candidate}"
      break
    fi
    echo "Invalid profile '${candidate}'. Allowed values: strict-prod or rootless-dev." >&2
  done
fi
validate_profile "${profile}" || die "invalid profile '${profile}' (expected strict-prod or rootless-dev)"

default_root="$(default_root_for_profile "${profile}")"
default_compose_project="$(default_compose_project_for_profile "${profile}")"
default_network="$(default_network_for_profile "${profile}")"
default_egress_network="$(default_egress_network_for_profile "${profile}")"

root_path="${root_override:-${default_root}}"
if [[ "${non_interactive}" -eq 0 && -z "${root_override}" ]]; then
  info "AGENTIC_ROOT is where persistent runtime files are stored."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_ROOT" "${root_path}")"
    if validate_path_value "${profile}" "AGENTIC_ROOT" "${candidate}"; then
      root_path="${candidate}"
      break
    fi
  done
else
  validate_path_value "${profile}" "AGENTIC_ROOT" "${root_path}" || die "invalid AGENTIC_ROOT"
fi

collect_text_value compose_project "AGENTIC_COMPOSE_PROJECT" "${default_compose_project}" "${compose_project_override}" validate_compose_or_network_name "AGENTIC_COMPOSE_PROJECT is the docker compose project name used to namespace resources."
collect_text_value network "AGENTIC_NETWORK" "${default_network}" "${network_override}" validate_compose_or_network_name "AGENTIC_NETWORK is the private docker network for internal traffic."
collect_text_value egress_network "AGENTIC_EGRESS_NETWORK" "${default_egress_network}" "${egress_network_override}" validate_compose_or_network_name "AGENTIC_EGRESS_NETWORK is dedicated to controlled outbound traffic."

collect_path_value ollama_models "OLLAMA_MODELS_DIR" "${profile}" "$(default_ollama_models_for_profile "${profile}" "${root_path}")" "${ollama_models_override}" "OLLAMA_MODELS_DIR points to the shared Ollama model storage path on host."
collect_text_value default_model "AGENTIC_DEFAULT_MODEL" "${AGENTIC_DEFAULT_MODEL:-llama3.1:8b}" "${default_model_override}" validate_model_id_value "AGENTIC_DEFAULT_MODEL controls the default local model used for preload and onboarding-generated OpenHands config."
grafana_admin_user="${grafana_admin_user_override:-${GRAFANA_ADMIN_USER:-admin}}"
grafana_admin_password="${grafana_admin_password_override:-${GRAFANA_ADMIN_PASSWORD:-replace-with-strong-password}}"
if [[ "${non_interactive}" -eq 0 && -z "${grafana_admin_password_override}" ]]; then
  info "GRAFANA_ADMIN_PASSWORD is used for first Grafana login (blank keeps current default)."
  grafana_admin_password="$(prompt_password_with_default "GRAFANA_ADMIN_PASSWORD" "${grafana_admin_password}")"
fi
validate_non_empty_single_line_value "GRAFANA_ADMIN_USER" "${grafana_admin_user}" || die "invalid GRAFANA_ADMIN_USER"
validate_non_empty_single_line_value "GRAFANA_ADMIN_PASSWORD" "${grafana_admin_password}" || die "invalid GRAFANA_ADMIN_PASSWORD"

collect_cpu_limit limits_default_cpus "AGENTIC_LIMIT_DEFAULT_CPUS" "$(default_limits_default_cpus_for_profile "${profile}")" "${limits_default_cpus_override}" "AGENTIC_LIMIT_DEFAULT_CPUS sets fallback CPU cap for all services."
collect_mem_limit limits_default_mem "AGENTIC_LIMIT_DEFAULT_MEM" "$(default_limits_default_mem_for_profile "${profile}")" "${limits_default_mem_override}"

collect_cpu_limit limits_core_cpus "AGENTIC_LIMIT_CORE_CPUS" "$(default_limits_stack_cpus_for_profile "${profile}" "core")" "${limits_core_cpus_override}" "AGENTIC_LIMIT_CORE_CPUS/AGENTIC_LIMIT_CORE_MEM set defaults for core services."
collect_mem_limit limits_core_mem "AGENTIC_LIMIT_CORE_MEM" "$(default_limits_stack_mem_for_profile "${profile}" "core")" "${limits_core_mem_override}"

collect_cpu_limit limits_agents_cpus "AGENTIC_LIMIT_AGENTS_CPUS" "$(default_limits_stack_cpus_for_profile "${profile}" "agents")" "${limits_agents_cpus_override}" "AGENTIC_LIMIT_AGENTS_CPUS/AGENTIC_LIMIT_AGENTS_MEM set defaults for agent containers."
collect_mem_limit limits_agents_mem "AGENTIC_LIMIT_AGENTS_MEM" "$(default_limits_stack_mem_for_profile "${profile}" "agents")" "${limits_agents_mem_override}"

collect_cpu_limit limits_ui_cpus "AGENTIC_LIMIT_UI_CPUS" "$(default_limits_stack_cpus_for_profile "${profile}" "ui")" "${limits_ui_cpus_override}" "AGENTIC_LIMIT_UI_CPUS/AGENTIC_LIMIT_UI_MEM set defaults for UI services."
collect_mem_limit limits_ui_mem "AGENTIC_LIMIT_UI_MEM" "$(default_limits_stack_mem_for_profile "${profile}" "ui")" "${limits_ui_mem_override}"

collect_cpu_limit limits_obs_cpus "AGENTIC_LIMIT_OBS_CPUS" "$(default_limits_stack_cpus_for_profile "${profile}" "obs")" "${limits_obs_cpus_override}" "AGENTIC_LIMIT_OBS_CPUS/AGENTIC_LIMIT_OBS_MEM set defaults for observability."
collect_mem_limit limits_obs_mem "AGENTIC_LIMIT_OBS_MEM" "$(default_limits_stack_mem_for_profile "${profile}" "obs")" "${limits_obs_mem_override}"

collect_cpu_limit limits_rag_cpus "AGENTIC_LIMIT_RAG_CPUS" "$(default_limits_stack_cpus_for_profile "${profile}" "rag")" "${limits_rag_cpus_override}" "AGENTIC_LIMIT_RAG_CPUS/AGENTIC_LIMIT_RAG_MEM set defaults for RAG services."
collect_mem_limit limits_rag_mem "AGENTIC_LIMIT_RAG_MEM" "$(default_limits_stack_mem_for_profile "${profile}" "rag")" "${limits_rag_mem_override}"

collect_cpu_limit limits_optional_cpus "AGENTIC_LIMIT_OPTIONAL_CPUS" "$(default_limits_stack_cpus_for_profile "${profile}" "optional")" "${limits_optional_cpus_override}" "AGENTIC_LIMIT_OPTIONAL_CPUS/AGENTIC_LIMIT_OPTIONAL_MEM set defaults for optional modules."
collect_mem_limit limits_optional_mem "AGENTIC_LIMIT_OPTIONAL_MEM" "$(default_limits_stack_mem_for_profile "${profile}" "optional")" "${limits_optional_mem_override}"

write_env_file \
  "${profile}" \
  "${root_path}" \
  "${compose_project}" \
  "${network}" \
  "${egress_network}" \
  "${ollama_models}" \
  "${default_model}" \
  "${grafana_admin_user}" \
  "${grafana_admin_password}" \
  "${limits_default_cpus}" \
  "${limits_default_mem}" \
  "${limits_core_cpus}" \
  "${limits_core_mem}" \
  "${limits_agents_cpus}" \
  "${limits_agents_mem}" \
  "${limits_ui_cpus}" \
  "${limits_ui_mem}" \
  "${limits_obs_cpus}" \
  "${limits_obs_mem}" \
  "${limits_rag_cpus}" \
  "${limits_rag_mem}" \
  "${limits_optional_cpus}" \
  "${limits_optional_mem}" \
  "${output_file}"
summary_add_generated "${output_file}"

root_is_writable=0
if runtime_root_writable "${root_path}"; then
  root_is_writable=1
fi

if [[ "${root_is_writable}" -ne 1 ]]; then
  warn "${root_path} is not writable for the current user; file bootstrap sections may be deferred."
fi

if [[ "${profile}" == "rootless-dev" ]]; then
  ollama_tmp_dir="$(default_ollama_tmp_for_models_dir "${ollama_models}")"

  if path_parent_writable_or_exists "${ollama_models}"; then
    install -d -m 0770 "${ollama_models}" \
      || summary_add_deferred "failed to create Ollama models directory: ${ollama_models}"
    if [[ -d "${ollama_models}" ]]; then
      summary_add_generated "${ollama_models}"
    fi
  else
    summary_add_deferred "Ollama models directory not created (parent not writable): ${ollama_models}"
  fi

  if [[ -n "${ollama_tmp_dir}" ]]; then
    if path_parent_writable_or_exists "${ollama_tmp_dir}"; then
      install -d -m 0770 "${ollama_tmp_dir}" \
        || summary_add_deferred "failed to create Ollama tmp directory: ${ollama_tmp_dir}"
      if [[ -d "${ollama_tmp_dir}" ]]; then
        summary_add_generated "${ollama_tmp_dir}"
      fi
    else
      summary_add_deferred "Ollama tmp directory not created (parent not writable): ${ollama_tmp_dir}"
    fi
  fi
fi

section "Section 2/4: UI Admin Bootstrap (OpenWebUI + OpenHands)"

ui_section_enabled=1
if [[ "${skip_ui_bootstrap}" -eq 1 ]]; then
  ui_section_enabled=0
elif [[ "${non_interactive}" -eq 0 ]]; then
  if [[ "${root_is_writable}" -eq 1 ]]; then
    prompt_yes_no "Configure OpenWebUI/OpenHands credentials now (recommended before first 'agent up ui')?" "yes" || ui_section_enabled=0
  else
    prompt_yes_no "Runtime root is not writable now. Still attempt UI credential bootstrap?" "no" || ui_section_enabled=0
  fi
fi

openwebui_admin_email="${openwebui_admin_email_override:-admin@local}"
openwebui_admin_password="${openwebui_admin_password_override:-change-me}"
openwebui_secret_key="${openwebui_secret_key_override:-change-me-openwebui-secret}"
openwebui_allow_model_pull_raw="${openwebui_allow_model_pull_override:-true}"
openwebui_enable_ollama_api="True"
openhands_llm_model="${openhands_llm_model_override:-${default_model}}"
openhands_llm_api_key="${openhands_llm_api_key_override:-local-ollama}"
openhands_llm_base_url="http://ollama-gate:11435/v1"

if [[ "${ui_section_enabled}" -eq 1 ]]; then
  if [[ "${non_interactive}" -eq 0 ]]; then
    while true; do
      candidate="$(prompt_with_default "WEBUI_ADMIN_EMAIL" "${openwebui_admin_email}")"
      if validate_email_value "WEBUI_ADMIN_EMAIL" "${candidate}"; then
        openwebui_admin_email="${candidate}"
        break
      fi
    done

    if [[ -z "${openwebui_admin_password_override}" ]]; then
      candidate="$(prompt_password_or_generate "WEBUI_ADMIN_PASSWORD")"
      if [[ -n "${candidate}" ]]; then
        openwebui_admin_password="${candidate}"
      else
        openwebui_admin_password="$(generate_secret_value 16)"
      fi
    fi

    if [[ -z "${openwebui_secret_key_override}" ]]; then
      candidate="$(prompt_secret_or_generate "WEBUI_SECRET_KEY")"
      if [[ -n "${candidate}" ]]; then
        openwebui_secret_key="${candidate}"
      else
        openwebui_secret_key="$(generate_secret_value 24)"
      fi
    fi

    if [[ -z "${openwebui_allow_model_pull_override}" ]]; then
      if prompt_yes_no "Allow pulling new models from OpenWebUI (native Ollama API)?" "yes"; then
        openwebui_allow_model_pull_raw="true"
      else
        openwebui_allow_model_pull_raw="false"
      fi
    fi

    openhands_llm_model="$(prompt_with_default "LLM_MODEL" "${openhands_llm_model}")"
    if [[ -z "${openhands_llm_api_key_override}" ]]; then
      info "OpenHands local mode accepts any non-empty LLM_API_KEY placeholder (example: local-ollama)."
      openhands_llm_api_key="$(prompt_secret_with_default "LLM_API_KEY" "${openhands_llm_api_key}")"
    fi
  fi

  validate_email_value "WEBUI_ADMIN_EMAIL" "${openwebui_admin_email}" || die "invalid WEBUI_ADMIN_EMAIL"
  [[ -n "${openwebui_admin_password}" ]] || die "WEBUI_ADMIN_PASSWORD cannot be empty"
  [[ -n "${openwebui_secret_key}" ]] || die "WEBUI_SECRET_KEY cannot be empty"
  [[ -n "${openhands_llm_model}" ]] || die "LLM_MODEL cannot be empty"
  [[ -n "${openhands_llm_api_key}" ]] || die "LLM_API_KEY cannot be empty"
  [[ -n "${openhands_llm_base_url}" ]] || die "LLM_BASE_URL cannot be empty"

  if [[ "${root_is_writable}" -ne 1 ]]; then
    summary_add_deferred "UI credentials were collected but not written because ${root_path} is not writable"
    if [[ "${require_complete}" -eq 1 ]]; then
      summary_add_blocker "UI bootstrap requested but runtime root is not writable"
    fi
  else
    openwebui_env_path="${root_path}/openwebui/config/openwebui.env"
    openwebui_env_content="WEBUI_ADMIN_EMAIL=${openwebui_admin_email}
WEBUI_ADMIN_PASSWORD=${openwebui_admin_password}
OPENAI_API_KEY=none
WEBUI_SECRET_KEY=${openwebui_secret_key}
OPENWEBUI_ENABLE_OLLAMA_API=${openwebui_enable_ollama_api}
"

    if ! write_file_atomic "${openwebui_env_path}" 0600 "${openwebui_env_content}"; then
      summary_add_blocker "failed to write ${openwebui_env_path}"
    else
      summary_add_generated "${openwebui_env_path}"
    fi

    openhands_env_path="${root_path}/openhands/config/openhands.env"
    openhands_env_content="LLM_API_KEY=${openhands_llm_api_key}
LLM_MODEL=${openhands_llm_model}
LLM_BASE_URL=${openhands_llm_base_url}
"

    if ! write_file_atomic "${openhands_env_path}" 0600 "${openhands_env_content}"; then
      summary_add_blocker "failed to write ${openhands_env_path}"
    else
      summary_add_generated "${openhands_env_path}"
    fi

    openhands_settings_path="${root_path}/openhands/state/settings.json"
    openhands_effective_model="$(normalize_openhands_model "${openhands_llm_model}")"
    openhands_settings_content="$(render_openhands_settings_json "${openhands_effective_model}" "${openhands_llm_api_key}" "${openhands_llm_base_url}")"
    if ! write_file_atomic "${openhands_settings_path}" 0660 "${openhands_settings_content}"; then
      summary_add_blocker "failed to write ${openhands_settings_path}"
    else
      summary_add_generated "${openhands_settings_path}"
    fi

    if [[ -f "${root_path}/openwebui/data/webui.db" ]]; then
      summary_add_deferred "${root_path}/openwebui/data/webui.db already exists: env credential changes do not reset existing users"
    fi
  fi
else
  summary_add_deferred "UI bootstrap skipped (openwebui/openhands env files not generated by onboard)"
fi

validate_true_false_value "OPENWEBUI_ALLOW_MODEL_PULL" "${openwebui_allow_model_pull_raw}" || die "invalid OPENWEBUI_ALLOW_MODEL_PULL"
openwebui_enable_ollama_api="$(normalize_true_false_env_value "${openwebui_allow_model_pull_raw}")" \
  || die "invalid OPENWEBUI_ALLOW_MODEL_PULL"
if ! upsert_export_in_file "${output_file}" "OPENWEBUI_ENABLE_OLLAMA_API" "${openwebui_enable_ollama_api}"; then
  summary_add_blocker "failed to persist OPENWEBUI_ENABLE_OLLAMA_API in ${output_file}"
fi

section "Section 3/4: Egress Allowlist Bootstrap"

network_section_enabled=1
if [[ "${skip_network_bootstrap}" -eq 1 ]]; then
  network_section_enabled=0
elif [[ "${non_interactive}" -eq 0 ]]; then
  if [[ "${root_is_writable}" -eq 1 ]]; then
    prompt_yes_no "Write initial proxy allowlist now?" "yes" || network_section_enabled=0
  else
    prompt_yes_no "Runtime root is not writable now. Still attempt allowlist bootstrap?" "no" || network_section_enabled=0
  fi
fi

default_allowlist_domains="$(default_allowlist_csv)"
if [[ -z "${default_allowlist_domains}" ]]; then
  default_allowlist_domains="example.com,api.openai.com,openrouter.ai"
fi

allowlist_domains="${allowlist_domains_override:-${default_allowlist_domains}}"
if [[ "${network_section_enabled}" -eq 1 ]]; then
  if [[ "${non_interactive}" -eq 0 && -z "${allowlist_domains_override}" ]]; then
    while true; do
      candidate="$(prompt_with_default "Allowlist domains/CIDR (comma-separated)" "${allowlist_domains}")"
      if validate_allowlist_csv "${candidate}"; then
        allowlist_domains="${candidate}"
        break
      fi
    done
  else
    validate_allowlist_csv "${allowlist_domains}" || die "invalid allowlist domains"
  fi

  if [[ "${root_is_writable}" -ne 1 ]]; then
    summary_add_deferred "allowlist values were collected but not written because ${root_path} is not writable"
    if [[ "${require_complete}" -eq 1 ]]; then
      summary_add_blocker "network bootstrap requested but runtime root is not writable"
    fi
  else
    allowlist_path="${root_path}/proxy/allowlist.txt"
    allowlist_lines="$(normalize_allowlist_csv "${allowlist_domains}")"
    allowlist_content="# One domain/CIDR per line (generated by agent onboard on $(date -u +"%Y-%m-%dT%H:%M:%SZ"))
${allowlist_lines}
"

    if ! write_file_atomic "${allowlist_path}" 0644 "${allowlist_content}"; then
      summary_add_blocker "failed to write ${allowlist_path}"
    else
      summary_add_generated "${allowlist_path}"
    fi
  fi
else
  summary_add_deferred "network bootstrap skipped (proxy allowlist not generated by onboard)"
fi

section "Section 4/4: Secret Bootstrap"

secret_section_enabled=1
if [[ "${skip_secret_bootstrap}" -eq 1 ]]; then
  secret_section_enabled=0
elif [[ "${non_interactive}" -eq 0 ]]; then
  if [[ "${root_is_writable}" -eq 1 ]]; then
    prompt_yes_no "Configure runtime secret files now?" "yes" || secret_section_enabled=0
  else
    prompt_yes_no "Runtime root is not writable now. Still attempt secret bootstrap?" "no" || secret_section_enabled=0
  fi
fi

openai_api_key="${openai_api_key_override:-}"
openrouter_api_key="${openrouter_api_key_override:-}"
optional_modules_raw="${optional_modules_override:-none}"
openclaw_token="${openclaw_token_override:-}"
openclaw_webhook_secret="${openclaw_webhook_secret_override:-}"
mcp_token="${mcp_token_override:-}"

if [[ "${secret_section_enabled}" -eq 1 ]]; then
  if [[ "${non_interactive}" -eq 0 ]]; then
    if [[ -z "${openai_api_key_override}" ]]; then
      openai_api_key="$(prompt_secret_with_default "openai.api_key (optional)" "${openai_api_key}")"
    fi
    if [[ -z "${openrouter_api_key_override}" ]]; then
      openrouter_api_key="$(prompt_secret_with_default "openrouter.api_key (optional)" "${openrouter_api_key}")"
    fi

    if [[ -z "${optional_modules_override}" ]]; then
      while true; do
        candidate="$(prompt_with_default "Optional modules to prepare secrets for (csv: none,openclaw,mcp,pi-mono,goose,portainer)" "${optional_modules_raw}")"
        if validate_optional_modules_csv "${candidate}"; then
          optional_modules_raw="${candidate}"
          break
        fi
      done
    else
      validate_optional_modules_csv "${optional_modules_raw}" || die "invalid --optional-modules"
    fi
  else
    validate_optional_modules_csv "${optional_modules_raw}" || die "invalid --optional-modules"
  fi

  normalized_modules="$(normalize_allowlist_csv "${optional_modules_raw}" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${normalized_modules}" ]]; then
    normalized_modules="none"
  fi

  if [[ "${normalized_modules}" == "none" ]]; then
    :
  else
    while IFS= read -r module; do
      [[ -n "${module}" ]] || continue
      summary_add_module "${module}"
      case "${module}" in
        openclaw)
          if [[ -z "${openclaw_token}" ]]; then
            if [[ "${non_interactive}" -eq 0 ]]; then
              candidate="$(prompt_secret_or_generate "openclaw.token")"
              if [[ -n "${candidate}" ]]; then
                openclaw_token="${candidate}"
              else
                openclaw_token="$(generate_secret_value 24)"
              fi
            else
              openclaw_token="$(generate_secret_value 24)"
            fi
          fi

          if [[ -z "${openclaw_webhook_secret}" ]]; then
            if [[ "${non_interactive}" -eq 0 ]]; then
              candidate="$(prompt_secret_or_generate "openclaw.webhook_secret")"
              if [[ -n "${candidate}" ]]; then
                openclaw_webhook_secret="${candidate}"
              else
                openclaw_webhook_secret="$(generate_secret_value 24)"
              fi
            else
              openclaw_webhook_secret="$(generate_secret_value 24)"
            fi
          fi
          ;;
        mcp)
          if [[ -z "${mcp_token}" ]]; then
            if [[ "${non_interactive}" -eq 0 ]]; then
              candidate="$(prompt_secret_or_generate "mcp.token")"
              if [[ -n "${candidate}" ]]; then
                mcp_token="${candidate}"
              else
                mcp_token="$(generate_secret_value 24)"
              fi
            else
              mcp_token="$(generate_secret_value 24)"
            fi
          fi
          ;;
        pi-mono|goose|portainer)
          ;;
      esac
    done <<<"${normalized_modules}"
  fi

  if [[ "${root_is_writable}" -ne 1 ]]; then
    summary_add_deferred "secret values were collected but not written because ${root_path} is not writable"
    if [[ "${normalized_modules}" != "none" ]]; then
      summary_add_deferred "optional request files were not written because ${root_path} is not writable"
    fi
    if [[ "${require_complete}" -eq 1 ]]; then
      summary_add_blocker "secret bootstrap requested but runtime root is not writable"
    fi
  else
    write_secret_file "${root_path}" "openai.api_key" "${openai_api_key}" || true
    write_secret_file "${root_path}" "openrouter.api_key" "${openrouter_api_key}" || true
    write_secret_file "${root_path}" "openclaw.token" "${openclaw_token}" || true
    write_secret_file "${root_path}" "openclaw.webhook_secret" "${openclaw_webhook_secret}" || true
    write_secret_file "${root_path}" "mcp.token" "${mcp_token}" || true

    if [[ "${normalized_modules}" != "none" ]]; then
      while IFS= read -r module; do
        [[ -n "${module}" && "${module}" != "none" ]] || continue
        ensure_optional_request_file "${root_path}" "${module}" || true
      done <<<"${normalized_modules}"
    fi
  fi
else
  summary_add_deferred "secret bootstrap skipped (no secret files generated by onboard)"
fi

if [[ "${skip_secret_bootstrap}" -eq 1 && -n "${optional_modules_override}" && "${optional_modules_override,,}" != "none" ]]; then
  summary_add_blocker "--optional-modules was provided while --skip-secret-bootstrap is enabled"
fi

if command -v git >/dev/null 2>&1 && git -C "${AGENTIC_REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rel_output="${output_file#${AGENTIC_REPO_ROOT}/}"
  if ! git -C "${AGENTIC_REPO_ROOT}" check-ignore -q "${rel_output}" 2>/dev/null; then
    warn "generated file is not git-ignored: ${output_file}"
  fi
fi

if [[ "${require_complete}" -eq 1 && "${#summary_deferred[@]}" -gt 0 ]]; then
  deferred_msg="$(printf '; %s' "${summary_deferred[@]}")"
  summary_add_blocker "incomplete onboarding with --require-complete${deferred_msg}"
fi

section "Onboarding Summary"
info "environment file generated: ${output_file}"

if [[ "${#summary_generated_files[@]}" -gt 0 ]]; then
  echo "Generated files:"
  for item in "${summary_generated_files[@]}"; do
    echo "  - ${item}"
  done
fi

if [[ "${#summary_modules[@]}" -gt 0 ]]; then
  echo "Modules prepared:"
  for module in "${summary_modules[@]}"; do
    echo "  - ${module}"
  done
fi

if [[ "${#summary_deferred[@]}" -gt 0 ]]; then
  echo "Deferred actions:"
  for item in "${summary_deferred[@]}"; do
    echo "  - ${item}"
  done
fi

echo
if [[ "${profile}" == "strict-prod" ]]; then
  echo "Next commands:"
  echo "  source \"${output_file}\""
  echo "  ./agent profile"
  echo "  sudo ./deployments/bootstrap/init_fs.sh"
  echo "  sudo ./agent up core"
  echo "  sudo ./agent up agents,ui,obs,rag"
  echo "  sudo ./agent doctor"
else
  echo "Next commands:"
  echo "  source \"${output_file}\""
  echo "  ./agent profile"
  echo "  ./deployments/bootstrap/init_fs.sh"
  echo "  ./agent up core"
  echo "  ./agent up agents,ui,obs,rag"
  echo "  ./agent doctor"
fi

if [[ -f "${root_path}/openwebui/data/webui.db" ]]; then
  echo
  echo "OpenWebUI note: existing user DB detected at ${root_path}/openwebui/data/webui.db"
  echo "If login remains invalid after credential update, reset OpenWebUI data explicitly:"
  if [[ "${profile}" == "strict-prod" ]]; then
    echo "  sudo ./agent forget openwebui --yes"
    echo "  sudo ./agent up ui"
  else
    echo "  ./agent forget openwebui --yes"
    echo "  ./agent up ui"
  fi
fi

if [[ "${#summary_blockers[@]}" -gt 0 ]]; then
  echo
  echo "Blocking issues:"
  for item in "${summary_blockers[@]}"; do
    echo "  - ${item}"
  done
  exit 1
fi

exit 0
