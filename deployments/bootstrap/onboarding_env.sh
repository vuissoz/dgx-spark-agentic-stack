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
non_interactive=0
output_file="${AGENTIC_ONBOARD_OUTPUT:-${AGENTIC_REPO_ROOT}/.runtime/env.generated.sh}"

usage() {
  cat <<'USAGE'
Usage:
  deployments/bootstrap/onboarding_env.sh [options]

Options:
  --profile <strict-prod|rootless-dev>
  --root <path>
  --compose-project <name>
  --network <name>
  --egress-network <name>
  --ollama-models-dir <path>
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
  --output <path>
  --non-interactive
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

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"
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
    printf '%s\n' "${AGENTIC_REPO_ROOT}/.runtime/ollama-models"
  else
    printf '%s\n' "${root_path}/ollama/models"
  fi
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
    warn "${key} parent '${parent}' is not writable for current user; this is acceptable in strict-prod when running setup with sudo later."
    return 0
  fi

  echo "${key} is not creatable from current user context (parent not writable: ${parent}). Choose another path or fix permissions." >&2
  return 1
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

normalize_output_path() {
  if [[ "${output_file}" != /* ]]; then
    output_file="${AGENTIC_REPO_ROOT}/${output_file}"
  fi
}

write_env_file() {
  local profile="$1"
  local root_path="$2"
  local compose_project="$3"
  local network="$4"
  local egress_network="$5"
  local ollama_models="$6"
  local limits_default_cpus="$7"
  local limits_default_mem="$8"
  local limits_core_cpus="$9"
  local limits_core_mem="${10}"
  local limits_agents_cpus="${11}"
  local limits_agents_mem="${12}"
  local limits_ui_cpus="${13}"
  local limits_ui_mem="${14}"
  local limits_obs_cpus="${15}"
  local limits_obs_mem="${16}"
  local limits_rag_cpus="${17}"
  local limits_rag_mem="${18}"
  local limits_optional_cpus="${19}"
  local limits_optional_mem="${20}"
  local out_file="${21}"
  local tmp_file=""

  install -d -m 0750 "$(dirname "${out_file}")"
  tmp_file="$(mktemp "${out_file}.tmp.XXXXXX")"
  cat >"${tmp_file}" <<EOF
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
EOF
  mv "${tmp_file}" "${out_file}"
  chmod 0640 "${out_file}"
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
    --output)
      [[ $# -ge 2 ]] || die "missing value for --output"
      output_file="$2"
      shift 2
      ;;
    --non-interactive)
      non_interactive=1
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

profile="${profile_override:-${AGENTIC_PROFILE}}"
if [[ "${non_interactive}" -eq 0 && -z "${profile_override}" ]]; then
  info "AGENTIC_PROFILE controls host mode: strict-prod (target CDC) or rootless-dev (local dev)."
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
  info "AGENTIC_ROOT is where persistent runtime folders are stored."
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

compose_project="${compose_project_override:-${default_compose_project}}"
if [[ "${non_interactive}" -eq 0 && -z "${compose_project_override}" ]]; then
  info "AGENTIC_COMPOSE_PROJECT is the docker compose project name used to namespace containers."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_COMPOSE_PROJECT" "${compose_project}")"
    if validate_compose_or_network_name "AGENTIC_COMPOSE_PROJECT" "${candidate}"; then
      compose_project="${candidate}"
      break
    fi
  done
else
  validate_compose_or_network_name "AGENTIC_COMPOSE_PROJECT" "${compose_project}" || die "invalid AGENTIC_COMPOSE_PROJECT"
fi

network="${network_override:-${default_network}}"
if [[ "${non_interactive}" -eq 0 && -z "${network_override}" ]]; then
  info "AGENTIC_NETWORK is the private internal docker network for services."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_NETWORK" "${network}")"
    if validate_compose_or_network_name "AGENTIC_NETWORK" "${candidate}"; then
      network="${candidate}"
      break
    fi
  done
else
  validate_compose_or_network_name "AGENTIC_NETWORK" "${network}" || die "invalid AGENTIC_NETWORK"
fi

egress_network="${egress_network_override:-${default_egress_network}}"
if [[ "${non_interactive}" -eq 0 && -z "${egress_network_override}" ]]; then
  info "AGENTIC_EGRESS_NETWORK is the dedicated docker network for controlled outbound traffic."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_EGRESS_NETWORK" "${egress_network}")"
    if validate_compose_or_network_name "AGENTIC_EGRESS_NETWORK" "${candidate}"; then
      egress_network="${candidate}"
      break
    fi
  done
else
  validate_compose_or_network_name "AGENTIC_EGRESS_NETWORK" "${egress_network}" || die "invalid AGENTIC_EGRESS_NETWORK"
fi

default_ollama_models="$(default_ollama_models_for_profile "${profile}" "${root_path}")"
ollama_models="${ollama_models_override:-${default_ollama_models}}"
if [[ "${non_interactive}" -eq 0 && -z "${ollama_models_override}" ]]; then
  info "OLLAMA_MODELS_DIR points to the shared Ollama model store path on the host."
  while true; do
    candidate="$(prompt_with_default "OLLAMA_MODELS_DIR" "${ollama_models}")"
    if validate_path_value "${profile}" "OLLAMA_MODELS_DIR" "${candidate}"; then
      ollama_models="${candidate}"
      break
    fi
  done
else
  validate_path_value "${profile}" "OLLAMA_MODELS_DIR" "${ollama_models}" || die "invalid OLLAMA_MODELS_DIR"
fi

default_limits_default_cpus="$(default_limits_default_cpus_for_profile "${profile}")"
limits_default_cpus="${limits_default_cpus_override:-${default_limits_default_cpus}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_default_cpus_override}" ]]; then
  info "AGENTIC_LIMIT_DEFAULT_CPUS sets the fallback CPU cap (cores) when no stack/service override is set."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_DEFAULT_CPUS" "${limits_default_cpus}")"
    if validate_cpu_limit_value "AGENTIC_LIMIT_DEFAULT_CPUS" "${candidate}"; then
      limits_default_cpus="${candidate}"
      break
    fi
  done
else
  validate_cpu_limit_value "AGENTIC_LIMIT_DEFAULT_CPUS" "${limits_default_cpus}" || die "invalid AGENTIC_LIMIT_DEFAULT_CPUS"
fi

default_limits_default_mem="$(default_limits_default_mem_for_profile "${profile}")"
limits_default_mem="${limits_default_mem_override:-${default_limits_default_mem}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_default_mem_override}" ]]; then
  info "AGENTIC_LIMIT_DEFAULT_MEM sets the fallback RAM cap when no stack/service override is set."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_DEFAULT_MEM" "${limits_default_mem}")"
    if validate_memory_limit_value "AGENTIC_LIMIT_DEFAULT_MEM" "${candidate}"; then
      limits_default_mem="${candidate}"
      break
    fi
  done
else
  validate_memory_limit_value "AGENTIC_LIMIT_DEFAULT_MEM" "${limits_default_mem}" || die "invalid AGENTIC_LIMIT_DEFAULT_MEM"
fi

default_limits_core_cpus="$(default_limits_stack_cpus_for_profile "${profile}" "core")"
limits_core_cpus="${limits_core_cpus_override:-${default_limits_core_cpus}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_core_cpus_override}" ]]; then
  info "AGENTIC_LIMIT_CORE_CPUS sets the default CPU cap for core services."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_CORE_CPUS" "${limits_core_cpus}")"
    if validate_cpu_limit_value "AGENTIC_LIMIT_CORE_CPUS" "${candidate}"; then
      limits_core_cpus="${candidate}"
      break
    fi
  done
else
  validate_cpu_limit_value "AGENTIC_LIMIT_CORE_CPUS" "${limits_core_cpus}" || die "invalid AGENTIC_LIMIT_CORE_CPUS"
fi

default_limits_core_mem="$(default_limits_stack_mem_for_profile "${profile}" "core")"
limits_core_mem="${limits_core_mem_override:-${default_limits_core_mem}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_core_mem_override}" ]]; then
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_CORE_MEM" "${limits_core_mem}")"
    if validate_memory_limit_value "AGENTIC_LIMIT_CORE_MEM" "${candidate}"; then
      limits_core_mem="${candidate}"
      break
    fi
  done
else
  validate_memory_limit_value "AGENTIC_LIMIT_CORE_MEM" "${limits_core_mem}" || die "invalid AGENTIC_LIMIT_CORE_MEM"
fi

default_limits_agents_cpus="$(default_limits_stack_cpus_for_profile "${profile}" "agents")"
limits_agents_cpus="${limits_agents_cpus_override:-${default_limits_agents_cpus}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_agents_cpus_override}" ]]; then
  info "AGENTIC_LIMIT_AGENTS_CPUS/AGENTIC_LIMIT_AGENTS_MEM set default caps for agent containers."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_AGENTS_CPUS" "${limits_agents_cpus}")"
    if validate_cpu_limit_value "AGENTIC_LIMIT_AGENTS_CPUS" "${candidate}"; then
      limits_agents_cpus="${candidate}"
      break
    fi
  done
else
  validate_cpu_limit_value "AGENTIC_LIMIT_AGENTS_CPUS" "${limits_agents_cpus}" || die "invalid AGENTIC_LIMIT_AGENTS_CPUS"
fi

default_limits_agents_mem="$(default_limits_stack_mem_for_profile "${profile}" "agents")"
limits_agents_mem="${limits_agents_mem_override:-${default_limits_agents_mem}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_agents_mem_override}" ]]; then
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_AGENTS_MEM" "${limits_agents_mem}")"
    if validate_memory_limit_value "AGENTIC_LIMIT_AGENTS_MEM" "${candidate}"; then
      limits_agents_mem="${candidate}"
      break
    fi
  done
else
  validate_memory_limit_value "AGENTIC_LIMIT_AGENTS_MEM" "${limits_agents_mem}" || die "invalid AGENTIC_LIMIT_AGENTS_MEM"
fi

default_limits_ui_cpus="$(default_limits_stack_cpus_for_profile "${profile}" "ui")"
limits_ui_cpus="${limits_ui_cpus_override:-${default_limits_ui_cpus}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_ui_cpus_override}" ]]; then
  info "AGENTIC_LIMIT_UI_CPUS/AGENTIC_LIMIT_UI_MEM set default caps for UI services."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_UI_CPUS" "${limits_ui_cpus}")"
    if validate_cpu_limit_value "AGENTIC_LIMIT_UI_CPUS" "${candidate}"; then
      limits_ui_cpus="${candidate}"
      break
    fi
  done
else
  validate_cpu_limit_value "AGENTIC_LIMIT_UI_CPUS" "${limits_ui_cpus}" || die "invalid AGENTIC_LIMIT_UI_CPUS"
fi

default_limits_ui_mem="$(default_limits_stack_mem_for_profile "${profile}" "ui")"
limits_ui_mem="${limits_ui_mem_override:-${default_limits_ui_mem}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_ui_mem_override}" ]]; then
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_UI_MEM" "${limits_ui_mem}")"
    if validate_memory_limit_value "AGENTIC_LIMIT_UI_MEM" "${candidate}"; then
      limits_ui_mem="${candidate}"
      break
    fi
  done
else
  validate_memory_limit_value "AGENTIC_LIMIT_UI_MEM" "${limits_ui_mem}" || die "invalid AGENTIC_LIMIT_UI_MEM"
fi

default_limits_obs_cpus="$(default_limits_stack_cpus_for_profile "${profile}" "obs")"
limits_obs_cpus="${limits_obs_cpus_override:-${default_limits_obs_cpus}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_obs_cpus_override}" ]]; then
  info "AGENTIC_LIMIT_OBS_CPUS/AGENTIC_LIMIT_OBS_MEM set default caps for observability services."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_OBS_CPUS" "${limits_obs_cpus}")"
    if validate_cpu_limit_value "AGENTIC_LIMIT_OBS_CPUS" "${candidate}"; then
      limits_obs_cpus="${candidate}"
      break
    fi
  done
else
  validate_cpu_limit_value "AGENTIC_LIMIT_OBS_CPUS" "${limits_obs_cpus}" || die "invalid AGENTIC_LIMIT_OBS_CPUS"
fi

default_limits_obs_mem="$(default_limits_stack_mem_for_profile "${profile}" "obs")"
limits_obs_mem="${limits_obs_mem_override:-${default_limits_obs_mem}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_obs_mem_override}" ]]; then
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_OBS_MEM" "${limits_obs_mem}")"
    if validate_memory_limit_value "AGENTIC_LIMIT_OBS_MEM" "${candidate}"; then
      limits_obs_mem="${candidate}"
      break
    fi
  done
else
  validate_memory_limit_value "AGENTIC_LIMIT_OBS_MEM" "${limits_obs_mem}" || die "invalid AGENTIC_LIMIT_OBS_MEM"
fi

default_limits_rag_cpus="$(default_limits_stack_cpus_for_profile "${profile}" "rag")"
limits_rag_cpus="${limits_rag_cpus_override:-${default_limits_rag_cpus}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_rag_cpus_override}" ]]; then
  info "AGENTIC_LIMIT_RAG_CPUS/AGENTIC_LIMIT_RAG_MEM set default caps for RAG services."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_RAG_CPUS" "${limits_rag_cpus}")"
    if validate_cpu_limit_value "AGENTIC_LIMIT_RAG_CPUS" "${candidate}"; then
      limits_rag_cpus="${candidate}"
      break
    fi
  done
else
  validate_cpu_limit_value "AGENTIC_LIMIT_RAG_CPUS" "${limits_rag_cpus}" || die "invalid AGENTIC_LIMIT_RAG_CPUS"
fi

default_limits_rag_mem="$(default_limits_stack_mem_for_profile "${profile}" "rag")"
limits_rag_mem="${limits_rag_mem_override:-${default_limits_rag_mem}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_rag_mem_override}" ]]; then
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_RAG_MEM" "${limits_rag_mem}")"
    if validate_memory_limit_value "AGENTIC_LIMIT_RAG_MEM" "${candidate}"; then
      limits_rag_mem="${candidate}"
      break
    fi
  done
else
  validate_memory_limit_value "AGENTIC_LIMIT_RAG_MEM" "${limits_rag_mem}" || die "invalid AGENTIC_LIMIT_RAG_MEM"
fi

default_limits_optional_cpus="$(default_limits_stack_cpus_for_profile "${profile}" "optional")"
limits_optional_cpus="${limits_optional_cpus_override:-${default_limits_optional_cpus}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_optional_cpus_override}" ]]; then
  info "AGENTIC_LIMIT_OPTIONAL_CPUS/AGENTIC_LIMIT_OPTIONAL_MEM set default caps for optional modules."
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_OPTIONAL_CPUS" "${limits_optional_cpus}")"
    if validate_cpu_limit_value "AGENTIC_LIMIT_OPTIONAL_CPUS" "${candidate}"; then
      limits_optional_cpus="${candidate}"
      break
    fi
  done
else
  validate_cpu_limit_value "AGENTIC_LIMIT_OPTIONAL_CPUS" "${limits_optional_cpus}" || die "invalid AGENTIC_LIMIT_OPTIONAL_CPUS"
fi

default_limits_optional_mem="$(default_limits_stack_mem_for_profile "${profile}" "optional")"
limits_optional_mem="${limits_optional_mem_override:-${default_limits_optional_mem}}"
if [[ "${non_interactive}" -eq 0 && -z "${limits_optional_mem_override}" ]]; then
  while true; do
    candidate="$(prompt_with_default "AGENTIC_LIMIT_OPTIONAL_MEM" "${limits_optional_mem}")"
    if validate_memory_limit_value "AGENTIC_LIMIT_OPTIONAL_MEM" "${candidate}"; then
      limits_optional_mem="${candidate}"
      break
    fi
  done
else
  validate_memory_limit_value "AGENTIC_LIMIT_OPTIONAL_MEM" "${limits_optional_mem}" || die "invalid AGENTIC_LIMIT_OPTIONAL_MEM"
fi

write_env_file \
  "${profile}" \
  "${root_path}" \
  "${compose_project}" \
  "${network}" \
  "${egress_network}" \
  "${ollama_models}" \
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

if command -v git >/dev/null 2>&1 && git -C "${AGENTIC_REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rel_output="${output_file#${AGENTIC_REPO_ROOT}/}"
  if ! git -C "${AGENTIC_REPO_ROOT}" check-ignore -q "${rel_output}" 2>/dev/null; then
    warn "generated file is not git-ignored: ${output_file}"
  fi
fi

info "environment file generated: ${output_file}"
echo
echo "Run the following commands:"
echo "  source \"${output_file}\""
echo "  ./agent profile"
