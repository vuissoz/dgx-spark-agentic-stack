#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

AGENT_RUNTIME_ENV_FILE="${AGENTIC_ROOT}/deployments/runtime.env"
AGENT_RELEASE_SNAPSHOT_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/releases/snapshot.sh"
AGENT_RELEASE_ROLLBACK_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/releases/rollback.sh"
AGENT_DOCKER_USER_ROLLBACK_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/net/rollback_docker_user.sh"
AGENT_DOCTOR_SCRIPT="${SCRIPT_DIR}/doctor.sh"
AGENT_OLLAMA_PRELOAD_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/ollama/preload_and_lock.sh"
AGENT_OLLAMA_LINK_SCRIPT="${AGENTIC_REPO_ROOT}/scripts/setup-ollama-models-link.sh"
AGENT_OLLAMA_LINK_ROLLBACK_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/ollama/rollback_models_link.sh"
AGENT_TOOLS=(claude codex opencode)
OPTIONAL_MODULES=(clawdbot mcp portainer)

usage() {
  cat <<USAGE
Usage:
  agent profile
  agent up <core|agents|ui|obs|rag|optional>
  agent down <core|agents|ui|obs|rag|optional>
  agent <claude|codex|opencode> [project]
  agent ls
  agent ps
  agent logs <service>
  agent stop <tool>
  agent net apply
  agent ollama-link
  agent ollama-preload [--generate-model <model>] [--embed-model <model>] [--budget-gb <int>] [--no-lock-ro]
  agent ollama-models <rw|ro>
  agent update
  agent rollback all <release_id>
  agent rollback host-net <backup_id>
  agent rollback ollama-link <backup_id|latest>
  agent test <A|B|C|D|E|F|G|H|I|J|K|all>
  agent doctor [--fix-net]

Optional modules (disabled by default):
  AGENTIC_OPTIONAL_MODULES=clawdbot,mcp,portainer agent up optional
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

tool_to_service() {
  case "$1" in
    claude) echo "agentic-claude" ;;
    codex) echo "agentic-codex" ;;
    opencode) echo "agentic-opencode" ;;
    *) return 1 ;;
  esac
}

stack_to_compose_file() {
  case "$1" in
    core) echo "${AGENTIC_COMPOSE_DIR}/compose.core.yml" ;;
    agents) echo "${AGENTIC_COMPOSE_DIR}/compose.agents.yml" ;;
    ui) echo "${AGENTIC_COMPOSE_DIR}/compose.ui.yml" ;;
    obs) echo "${AGENTIC_COMPOSE_DIR}/compose.obs.yml" ;;
    rag) echo "${AGENTIC_COMPOSE_DIR}/compose.rag.yml" ;;
    optional) echo "${AGENTIC_COMPOSE_DIR}/compose.optional.yml" ;;
    *) die "Unknown target stack: $1" ;;
  esac
}

parse_targets() {
  local raw="$1"
  if [[ "$raw" == "all" ]]; then
    echo "core agents ui obs rag optional"
    return 0
  fi

  raw="${raw//,/ }"
  echo "$raw"
}

join_targets_csv() {
  local -a parts=("$@")
  local out=""
  local item
  for item in "${parts[@]}"; do
    if [[ -z "${out}" ]]; then
      out="${item}"
    else
      out="${out},${item}"
    fi
  done
  printf '%s\n' "${out}"
}

targets_include() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

optional_module_profile() {
  case "$1" in
    clawdbot) echo "optional-clawdbot" ;;
    mcp) echo "optional-mcp" ;;
    portainer) echo "optional-portainer" ;;
    *) return 1 ;;
  esac
}

optional_module_secret_file() {
  case "$1" in
    clawdbot) echo "${AGENTIC_ROOT}/secrets/runtime/clawdbot.token" ;;
    mcp) echo "${AGENTIC_ROOT}/secrets/runtime/mcp.token" ;;
    portainer) echo "" ;;
    *) return 1 ;;
  esac
}

parse_optional_modules() {
  local raw="${AGENTIC_OPTIONAL_MODULES:-}"
  local module
  local -a parsed=()
  local -A seen=()

  [[ -n "${raw}" ]] || return 0
  raw="${raw//,/ }"

  for module in ${raw}; do
    [[ -n "${module}" ]] || continue
    optional_module_profile "${module}" >/dev/null \
      || die "Unknown optional module '${module}'. Allowed modules: ${OPTIONAL_MODULES[*]}"
    if [[ -z "${seen[${module}]:-}" ]]; then
      parsed+=("${module}")
      seen["${module}"]=1
    fi
  done

  printf '%s\n' "${parsed[@]}"
}

validate_optional_request_file() {
  local module="$1"
  local request_file="${AGENTIC_ROOT}/deployments/optional/${module}.request"

  [[ -f "${request_file}" ]] || die "Optional module '${module}' requires request file: ${request_file}"
  grep -Eq '^need=[^[:space:]].+$' "${request_file}" \
    || die "Optional module '${module}' request is missing a non-empty 'need=' entry: ${request_file}"
  grep -Eq '^success=[^[:space:]].+$' "${request_file}" \
    || die "Optional module '${module}' request is missing a non-empty 'success=' entry: ${request_file}"
}

validate_optional_module_prereqs() {
  local module="$1"
  local secret_file
  local secret_mode

  validate_optional_request_file "${module}"
  secret_file="$(optional_module_secret_file "${module}")" || return 1
  if [[ -n "${secret_file}" ]]; then
    [[ -s "${secret_file}" ]] \
      || die "Optional module '${module}' requires a secret file with mode 600: ${secret_file}"
    secret_mode="$(stat -c '%a' "${secret_file}" 2>/dev/null || echo "")"
    if [[ "${secret_mode}" != "600" && "${secret_mode}" != "640" ]]; then
      die "Optional module '${module}' secret must use restrictive permissions (600/640): ${secret_file} (mode=${secret_mode:-unknown})"
    fi
  fi
}

log_optional_activation() {
  local module="$1"
  local request_file="${AGENTIC_ROOT}/deployments/optional/${module}.request"
  local changes_log="${AGENTIC_ROOT}/deployments/changes.log"
  local actor="${SUDO_USER:-${USER:-unknown}}"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${changes_log}"
  chmod 0640 "${changes_log}" || true

  printf '%s optional module enabled module=%s actor=%s request=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${module}" "${actor}" "${request_file}" \
    >>"${changes_log}"
}

service_container_id() {
  local service="$1"
  docker ps \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}' | head -n 1
}

existing_compose_files() {
  local -a ordered_targets=(core agents ui obs rag optional)
  local target
  local compose_file
  for target in "${ordered_targets[@]}"; do
    compose_file="$(stack_to_compose_file "$target")"
    if [[ -f "${compose_file}" ]]; then
      printf '%s\n' "${compose_file}"
    fi
  done
}

load_runtime_env() {
  [[ -f "${AGENT_RUNTIME_ENV_FILE}" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" != \#* ]] || continue
    [[ "${line}" == *=* ]] || continue

    key="${line%%=*}"
    value="${line#*=}"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    case "${key}" in
      OLLAMA_CONTAINER_MODELS_PATH)
        if [[ "${AGENTIC_PROFILE}" != "rootless-dev" ]]; then
          export "${key}=${value}"
        fi
        ;;
      AGENTIC_OLLAMA_MODELS_LINK|AGENTIC_OLLAMA_MODELS_TARGET_DIR|OLLAMA_MODELS_DIR|OLLAMA_CONTAINER_USER|OLLAMA_MODELS_MOUNT_MODE|OLLAMA_PRELOAD_GENERATE_MODEL|OLLAMA_PRELOAD_EMBED_MODEL|OLLAMA_MODEL_STORE_BUDGET_GB|RAG_EMBED_MODEL)
        export "${key}=${value}"
        ;;
      *)
        ;;
    esac
  done < "${AGENT_RUNTIME_ENV_FILE}"
}

set_runtime_env_value() {
  local key="$1"
  local value="$2"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${AGENT_RUNTIME_ENV_FILE}"
  chmod 0640 "${AGENT_RUNTIME_ENV_FILE}" || true

  if grep -Eq "^${key}=" "${AGENT_RUNTIME_ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|g" "${AGENT_RUNTIME_ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${AGENT_RUNTIME_ENV_FILE}"
  fi
}

ensure_runtime_env() {
  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${AGENT_RUNTIME_ENV_FILE}"
  chmod 0640 "${AGENT_RUNTIME_ENV_FILE}"

  local -a keys=(
    "AGENTIC_PROFILE=${AGENTIC_PROFILE}"
    "AGENTIC_ROOT=${AGENTIC_ROOT}"
    "AGENTIC_COMPOSE_PROJECT=${AGENTIC_COMPOSE_PROJECT}"
    "AGENTIC_NETWORK=${AGENTIC_NETWORK}"
    "AGENTIC_EGRESS_NETWORK=${AGENTIC_EGRESS_NETWORK}"
    "AGENTIC_OLLAMA_MODELS_LINK=${AGENTIC_OLLAMA_MODELS_LINK}"
    "AGENTIC_OLLAMA_MODELS_TARGET_DIR=${AGENTIC_OLLAMA_MODELS_TARGET_DIR:-}"
    "OLLAMA_MODELS_DIR=${OLLAMA_MODELS_DIR}"
    "OLLAMA_CONTAINER_MODELS_PATH=${OLLAMA_CONTAINER_MODELS_PATH}"
    "OLLAMA_CONTAINER_USER=${OLLAMA_CONTAINER_USER}"
    "OLLAMA_MODELS_MOUNT_MODE=${OLLAMA_MODELS_MOUNT_MODE}"
    "OLLAMA_PRELOAD_GENERATE_MODEL=${OLLAMA_PRELOAD_GENERATE_MODEL}"
    "OLLAMA_PRELOAD_EMBED_MODEL=${OLLAMA_PRELOAD_EMBED_MODEL}"
    "OLLAMA_MODEL_STORE_BUDGET_GB=${OLLAMA_MODEL_STORE_BUDGET_GB}"
    "RAG_EMBED_MODEL=${RAG_EMBED_MODEL}"
  )

  local kv key
  for kv in "${keys[@]}"; do
    key="${kv%%=*}"
    if grep -Eq "^${key}=" "${AGENT_RUNTIME_ENV_FILE}"; then
      sed -i "s#^${key}=.*#${kv}#g" "${AGENT_RUNTIME_ENV_FILE}"
    else
      printf '%s\n' "${kv}" >>"${AGENT_RUNTIME_ENV_FILE}"
    fi
  done
}

cmd_profile() {
  printf 'profile=%s\n' "${AGENTIC_PROFILE}"
  printf 'root=%s\n' "${AGENTIC_ROOT}"
  printf 'compose_project=%s\n' "${AGENTIC_COMPOSE_PROJECT}"
  printf 'network=%s\n' "${AGENTIC_NETWORK}"
  printf 'egress_network=%s\n' "${AGENTIC_EGRESS_NETWORK}"
  printf 'ollama_models_dir=%s\n' "${OLLAMA_MODELS_DIR}"
  printf 'ollama_models_link=%s\n' "${AGENTIC_OLLAMA_MODELS_LINK}"
  printf 'ollama_models_target_dir=%s\n' "${AGENTIC_OLLAMA_MODELS_TARGET_DIR:-}"
  printf 'ollama_container_models_path=%s\n' "${OLLAMA_CONTAINER_MODELS_PATH}"
  printf 'ollama_container_user=%s\n' "${OLLAMA_CONTAINER_USER}"
  printf 'ollama_models_mount_mode=%s\n' "${OLLAMA_MODELS_MOUNT_MODE}"
  printf 'ollama_preload_generate_model=%s\n' "${OLLAMA_PRELOAD_GENERATE_MODEL}"
  printf 'ollama_preload_embed_model=%s\n' "${OLLAMA_PRELOAD_EMBED_MODEL}"
  printf 'ollama_model_store_budget_gb=%s\n' "${OLLAMA_MODEL_STORE_BUDGET_GB}"
  printf 'rag_embed_model=%s\n' "${RAG_EMBED_MODEL}"
  printf 'skip_docker_user_apply=%s\n' "${AGENTIC_SKIP_DOCKER_USER_APPLY:-0}"
  printf 'skip_docker_user_check=%s\n' "${AGENTIC_SKIP_DOCKER_USER_CHECK:-0}"
  printf 'skip_doctor_proxy_check=%s\n' "${AGENTIC_SKIP_DOCTOR_PROXY_CHECK:-0}"
}

run_compose_on_targets() {
  local action="$1"
  local target_arg="$2"
  shift 2
  local -a compose_args=()
  local -a profile_args=()
  local -a selected_targets=()
  local compose_file

  local target
  for target in $(parse_targets "$target_arg"); do
    selected_targets+=("${target}")
    compose_file="$(stack_to_compose_file "$target")"
    [[ -f "$compose_file" ]] || die "Compose file not found for target '$target': $compose_file"
    compose_args+=("-f" "$compose_file")
  done

  if targets_include optional "${selected_targets[@]}"; then
    profile_args+=("--profile" "optional")
  fi

  require_cmd docker
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" "${profile_args[@]}" "${compose_args[@]}" "$action" "$@"
}

ensure_core_runtime() {
  if [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]]; then
    [[ -x "${AGENT_OLLAMA_LINK_SCRIPT}" ]] || die "missing script: ${AGENT_OLLAMA_LINK_SCRIPT}"
    if ! "${AGENT_OLLAMA_LINK_SCRIPT}" --quiet >/tmp/agent-ollama-link.out 2>&1; then
      cat /tmp/agent-ollama-link.out >&2
      die "failed to initialize rootless ollama models symlink"
    fi
    OLLAMA_MODELS_DIR="$(sed -n 's/^OLLAMA_MODELS_DIR=//p' /tmp/agent-ollama-link.out | tail -n 1)"
    [[ -n "${OLLAMA_MODELS_DIR}" ]] || die "rootless ollama models link script did not return OLLAMA_MODELS_DIR"
    export OLLAMA_MODELS_DIR
  fi

  if ! "${AGENTIC_REPO_ROOT}/deployments/core/init_runtime.sh"; then
    die "failed to initialize core runtime in ${AGENTIC_ROOT}; re-run with sudo or set AGENTIC_ROOT to a writable path"
  fi
}

ensure_agents_runtime() {
  if ! "${AGENTIC_REPO_ROOT}/deployments/agents/init_runtime.sh"; then
    die "failed to initialize agents runtime in ${AGENTIC_ROOT}; re-run with sudo or set AGENTIC_ROOT to a writable path"
  fi
}

ensure_obs_runtime() {
  if ! "${AGENTIC_REPO_ROOT}/deployments/obs/init_runtime.sh"; then
    die "failed to initialize obs runtime in ${AGENTIC_ROOT}; re-run with sudo or set AGENTIC_ROOT to a writable path"
  fi
}

ensure_ui_runtime() {
  if ! "${AGENTIC_REPO_ROOT}/deployments/ui/init_runtime.sh"; then
    die "failed to initialize ui runtime in ${AGENTIC_ROOT}; re-run with sudo or set AGENTIC_ROOT to a writable path"
  fi
}

ensure_rag_runtime() {
  if ! "${AGENTIC_REPO_ROOT}/deployments/rag/init_runtime.sh"; then
    die "failed to initialize rag runtime in ${AGENTIC_ROOT}; re-run with sudo or set AGENTIC_ROOT to a writable path"
  fi
}

ensure_optional_runtime() {
  if ! "${AGENTIC_REPO_ROOT}/deployments/optional/init_runtime.sh"; then
    die "failed to initialize optional runtime in ${AGENTIC_ROOT}; re-run with sudo or set AGENTIC_ROOT to a writable path"
  fi
}

apply_core_network_policy() {
  if [[ "${AGENTIC_SKIP_DOCKER_USER_APPLY:-0}" == "1" ]]; then
    warn "skipping DOCKER-USER policy apply because AGENTIC_SKIP_DOCKER_USER_APPLY=1"
    return 0
  fi
  if ! "${AGENTIC_REPO_ROOT}/deployments/net/apply_docker_user.sh"; then
    die "failed to apply DOCKER-USER policy; re-run with sudo or set AGENTIC_SKIP_DOCKER_USER_APPLY=1 for local dry-runs"
  fi
}

detect_project_name() {
  local project
  if [[ -n "${AGENT_PROJECT_NAME:-}" ]]; then
    project="${AGENT_PROJECT_NAME}"
  elif project_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    project="$(basename "${project_root}")"
  else
    project="$(basename "${PWD}")"
  fi

  project="${project// /-}"
  project="${project//[^a-zA-Z0-9._-]/-}"
  printf '%s\n' "${project}"
}

prepare_tool_session() {
  local tool="$1"
  local project="$2"
  local service container_id workspace

  service="$(tool_to_service "${tool}")" || die "Unknown tool '${tool}'"
  container_id="$(service_container_id "${service}")"
  [[ -n "${container_id}" ]] || die "Service '${service}' is not running. Start it with: agent up agents"

  workspace="/workspace/${project}"
  docker exec "${container_id}" sh -lc "mkdir -p '${workspace}'"

  if ! docker exec "${container_id}" tmux has-session -t "${tool}" >/dev/null 2>&1; then
    docker exec "${container_id}" tmux new-session -d -s "${tool}" -c "${workspace}" "bash -lc 'exec bash -l'"
  fi
  docker exec "${container_id}" sh -lc "tmux send-keys -t '${tool}' C-c 'cd \"${workspace}\"' C-m"
}

cmd_tool_attach() {
  local tool="$1"
  local project="${2:-$(detect_project_name)}"
  local service container_id

  prepare_tool_session "${tool}" "${project}"
  service="$(tool_to_service "${tool}")"
  container_id="$(service_container_id "${service}")"

  if [[ "${AGENT_NO_ATTACH:-0}" == "1" ]]; then
    printf 'prepared tool=%s project=%s container=%s\n' "${tool}" "${project}" "${container_id}"
    return 0
  fi

  exec docker exec -it "${container_id}" tmux attach-session -t "${tool}"
}

sticky_model_for_session() {
  local session_name="$1"
  local sticky_file="${AGENTIC_ROOT}/gate/state/sticky_sessions.json"

  if [[ ! -f "${sticky_file}" ]]; then
    printf '%s\n' "-"
    return 0
  fi

  python3 - "${sticky_file}" "${session_name}" <<'PY'
import json
import sys

path = sys.argv[1]
session = sys.argv[2]

try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("-")
    raise SystemExit(0)

value = data.get(session)
if isinstance(value, str) and value:
    print(value)
else:
    print("-")
PY
}

cmd_ls() {
  require_cmd docker

  printf 'tool\tservice\tstatus\ttmux\tworkspace\tsticky_model\n'

  local tool service container_id status tmux_status workspace_size sticky
  for tool in "${AGENT_TOOLS[@]}"; do
    service="$(tool_to_service "${tool}")"
    container_id="$(service_container_id "${service}")"

    status="down"
    tmux_status="-"
    if [[ -n "${container_id}" ]]; then
      status="$(docker inspect --format '{{.State.Status}}' "${container_id}" 2>/dev/null || echo unknown)"
      if docker exec "${container_id}" tmux has-session -t "${tool}" >/dev/null 2>&1; then
        tmux_status="up"
      else
        tmux_status="missing"
      fi
    fi

    if [[ -d "${AGENTIC_ROOT}/${tool}/workspaces" ]]; then
      workspace_size="$(du -sh "${AGENTIC_ROOT}/${tool}/workspaces" 2>/dev/null | awk '{print $1}')"
      workspace_size="${workspace_size:-0B}"
    else
      workspace_size="n/a"
    fi

    sticky="$(sticky_model_for_session "${tool}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${tool}" "${service}" "${status}" "${tmux_status}" "${workspace_size}" "${sticky}"
  done
}

cmd_stop() {
  local tool="${1:-}"
  local service compose_file
  [[ -n "${tool}" ]] || die "Usage: agent stop <tool>"

  service="$(tool_to_service "${tool}")" || die "Unknown tool '${tool}'. Expected one of: ${AGENT_TOOLS[*]}"
  compose_file="$(stack_to_compose_file agents)"
  [[ -f "${compose_file}" ]] || die "Compose file not found for agents stack: ${compose_file}"

  require_cmd docker
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${compose_file}" stop "${service}"
}

cmd_ollama_models_mode() {
  local mode="${1:-}"
  [[ "${mode}" == "rw" || "${mode}" == "ro" ]] || die "Usage: agent ollama-models <rw|ro>"

  ensure_runtime_env
  ensure_core_runtime
  set_runtime_env_value "OLLAMA_MODELS_MOUNT_MODE" "${mode}"
  export OLLAMA_MODELS_MOUNT_MODE="${mode}"

  local core_compose_file
  core_compose_file="$(stack_to_compose_file core)"
  [[ -f "${core_compose_file}" ]] || die "Compose file not found for core stack: ${core_compose_file}"

  require_cmd docker
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${core_compose_file}" up -d --force-recreate ollama
  printf 'ollama models mount mode updated to %s\n' "${mode}"
}

cmd_ollama_preload() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]; then
    [[ -x "${AGENT_OLLAMA_PRELOAD_SCRIPT}" ]] || die "preload script missing: ${AGENT_OLLAMA_PRELOAD_SCRIPT}"
    exec "${AGENT_OLLAMA_PRELOAD_SCRIPT}" --help
  fi

  ensure_runtime_env
  ensure_core_runtime
  [[ -x "${AGENT_OLLAMA_PRELOAD_SCRIPT}" ]] || die "preload script missing: ${AGENT_OLLAMA_PRELOAD_SCRIPT}"

  "${AGENT_OLLAMA_PRELOAD_SCRIPT}" "$@"
}

cmd_ollama_link() {
  [[ -x "${AGENT_OLLAMA_LINK_SCRIPT}" ]] || die "missing script: ${AGENT_OLLAMA_LINK_SCRIPT}"
  ensure_runtime_env
  "${AGENT_OLLAMA_LINK_SCRIPT}"
}

cmd_net() {
  local action="${1:-}"
  case "${action}" in
    apply)
      ensure_runtime_env
      apply_core_network_policy
      ;;
    *)
      die "Usage: agent net apply"
      ;;
  esac
}

cmd_update() {
  ensure_runtime_env
  require_cmd docker
  [[ -x "${AGENT_RELEASE_SNAPSHOT_SCRIPT}" ]] || die "snapshot script missing: ${AGENT_RELEASE_SNAPSHOT_SCRIPT}"

  local -a compose_files=()
  mapfile -t compose_files < <(existing_compose_files)
  [[ "${#compose_files[@]}" -gt 0 ]] || die "No compose files available to update"

  local -a compose_args=()
  local compose_file
  for compose_file in "${compose_files[@]}"; do
    compose_args+=("-f" "${compose_file}")
  done

  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" "${compose_args[@]}" pull --ignore-pull-failures
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" "${compose_args[@]}" up -d --remove-orphans

  local release_id
  release_id="$("${AGENT_RELEASE_SNAPSHOT_SCRIPT}" --reason update "${compose_files[@]}")"
  printf 'update completed, release=%s\n' "${release_id}"
}

cmd_rollback() {
  local scope="${1:-}"
  local target_id="${2:-}"
  ensure_runtime_env

  case "${scope}" in
    all)
      [[ -n "${target_id}" ]] || die "Usage: agent rollback all <release_id>"
      [[ -x "${AGENT_RELEASE_ROLLBACK_SCRIPT}" ]] || die "rollback script missing: ${AGENT_RELEASE_ROLLBACK_SCRIPT}"
      "${AGENT_RELEASE_ROLLBACK_SCRIPT}" "${target_id}"
      ;;
    host-net)
      [[ -n "${target_id}" ]] || die "Usage: agent rollback host-net <backup_id>"
      [[ -x "${AGENT_DOCKER_USER_ROLLBACK_SCRIPT}" ]] || die "host-net rollback script missing: ${AGENT_DOCKER_USER_ROLLBACK_SCRIPT}"
      "${AGENT_DOCKER_USER_ROLLBACK_SCRIPT}" "${target_id}"
      ;;
    ollama-link)
      [[ -n "${target_id}" ]] || die "Usage: agent rollback ollama-link <backup_id|latest>"
      [[ -x "${AGENT_OLLAMA_LINK_ROLLBACK_SCRIPT}" ]] || die "ollama-link rollback script missing: ${AGENT_OLLAMA_LINK_ROLLBACK_SCRIPT}"
      "${AGENT_OLLAMA_LINK_ROLLBACK_SCRIPT}" "${target_id}"
      ;;
    *)
      die "Usage: agent rollback all <release_id> | agent rollback host-net <backup_id> | agent rollback ollama-link <backup_id|latest>"
      ;;
  esac
}

normalize_logs_target() {
  local target="$1"
  case "${target}" in
    claude|codex|opencode) tool_to_service "${target}" ;;
    *) printf '%s\n' "${target}" ;;
  esac
}

run_tests() {
  local selector="$1"
  local -a tests=()

  if [[ "$selector" == "all" ]]; then
    mapfile -t tests < <(
      find "${AGENTIC_TEST_DIR}" -maxdepth 1 -type f -regextype posix-extended \
        -regex '.*/([0-9]+|[A-Z][0-9]*)_.*\.sh' | sort
    )
  elif [[ "$selector" =~ ^[A-K]$ ]]; then
    mapfile -t tests < <(
      find "${AGENTIC_TEST_DIR}" -maxdepth 1 -type f -regextype posix-extended \
        -regex ".*/${selector}([0-9]+)?_.*\\.sh" | sort
    )
  else
    die "Invalid test selector '$selector'. Expected one of A..K or all."
  fi

  [[ "${#tests[@]}" -gt 0 ]] || die "No test scripts found for selector '$selector'."

  local test_script
  for test_script in "${tests[@]}"; do
    echo "RUN ${test_script}"
    bash "${test_script}"
  done
}

load_runtime_env

cmd="${1:-}"
[[ -n "$cmd" ]] || {
  usage
  exit 1
}

case "$cmd" in
  profile)
    cmd_profile
    ;;
  up)
    [[ $# -ge 2 ]] || die "Usage: agent up <core|agents|ui|obs|rag|optional>"
    target_arg="$2"
    if [[ "${target_arg}" == "all" ]]; then
      target_arg="core,agents,ui,obs,rag"
    fi
    read -r -a targets <<<"$(parse_targets "$target_arg")"
    ensure_runtime_env

    if targets_include "core" "${targets[@]}"; then
      ensure_core_runtime
    fi
    if targets_include "agents" "${targets[@]}"; then
      ensure_agents_runtime
    fi
    if targets_include "obs" "${targets[@]}"; then
      ensure_obs_runtime
    fi
    if targets_include "ui" "${targets[@]}"; then
      ensure_ui_runtime
    fi
    if targets_include "rag" "${targets[@]}"; then
      ensure_rag_runtime
    fi
    if targets_include "optional" "${targets[@]}"; then
      non_optional_targets=()
      optional_profiles=(--profile optional)
      optional_compose_file="$(stack_to_compose_file optional)"
      optional_modules=()
      for target in "${targets[@]}"; do
        [[ "${target}" == "optional" ]] && continue
        non_optional_targets+=("${target}")
      done

      if [[ "${#non_optional_targets[@]}" -gt 0 ]]; then
        run_compose_on_targets up "$(join_targets_csv "${non_optional_targets[@]}")" -d
      fi

      if [[ "${AGENTIC_SKIP_OPTIONAL_GATING:-0}" != "1" ]]; then
        if ! "${AGENT_DOCTOR_SCRIPT}" >/tmp/agent-optional-gate.out 2>&1; then
          cat /tmp/agent-optional-gate.out >&2
          die "optional stack gating refused because 'agent doctor' is not green (set AGENTIC_SKIP_OPTIONAL_GATING=1 to bypass intentionally)"
        fi
      else
        warn "skipping optional stack doctor gating because AGENTIC_SKIP_OPTIONAL_GATING=1"
      fi

      ensure_optional_runtime
      mapfile -t optional_modules < <(parse_optional_modules)
      if [[ "${#optional_modules[@]}" -gt 0 ]]; then
        for optional_module in "${optional_modules[@]}"; do
          validate_optional_module_prereqs "${optional_module}"
          optional_profiles+=(--profile "$(optional_module_profile "${optional_module}")")
          log_optional_activation "${optional_module}"
        done
      fi

      require_cmd docker
      docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" \
        "${optional_profiles[@]}" \
        -f "${optional_compose_file}" up -d
    else
      run_compose_on_targets up "$target_arg" -d
    fi

    if targets_include "core" "${targets[@]}"; then
      apply_core_network_policy
    fi
    ;;
  down)
    [[ $# -ge 2 ]] || die "Usage: agent down <core|agents|ui|obs|rag|optional>"
    target_arg="$2"
    read -r -a targets <<<"$(parse_targets "$target_arg")"
    if targets_include "optional" "${targets[@]}"; then
      non_optional_targets=()
      for target in "${targets[@]}"; do
        [[ "${target}" == "optional" ]] && continue
        non_optional_targets+=("${target}")
      done

      if [[ "${#non_optional_targets[@]}" -gt 0 ]]; then
        run_compose_on_targets down "$(join_targets_csv "${non_optional_targets[@]}")"
      fi

      require_cmd docker
      docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" \
        --profile optional \
        --profile optional-clawdbot \
        --profile optional-mcp \
        --profile optional-portainer \
        -f "$(stack_to_compose_file optional)" down
    else
      run_compose_on_targets down "$target_arg"
    fi
    ;;
  claude|codex|opencode)
    shift
    cmd_tool_attach "${cmd}" "${1:-}"
    ;;
  ls)
    cmd_ls
    ;;
  ps)
    require_cmd docker
    docker ps \
      --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    ;;
  logs)
    [[ $# -ge 2 ]] || die "Usage: agent logs <service>"
    require_cmd docker
    docker logs --tail "${AGENT_LOG_TAIL:-200}" -f "$(normalize_logs_target "$2")"
    ;;
  stop)
    [[ $# -ge 2 ]] || die "Usage: agent stop <tool>"
    cmd_stop "$2"
    ;;
  net)
    shift
    cmd_net "${1:-}"
    ;;
  ollama-link)
    cmd_ollama_link
    ;;
  ollama-models)
    [[ $# -ge 2 ]] || die "Usage: agent ollama-models <rw|ro>"
    cmd_ollama_models_mode "$2"
    ;;
  ollama-preload)
    shift
    cmd_ollama_preload "$@"
    ;;
  update)
    cmd_update
    ;;
  rollback)
    [[ $# -ge 3 ]] || die "Usage: agent rollback all <release_id> | agent rollback host-net <backup_id> | agent rollback ollama-link <backup_id|latest>"
    cmd_rollback "$2" "$3"
    ;;
  test)
    [[ $# -ge 2 ]] || die "Usage: agent test <A|B|...|K|all>"
    run_tests "$2"
    ;;
  doctor)
    shift
    exec "${SCRIPT_DIR}/doctor.sh" "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    die "Unknown command: $cmd"
    ;;
esac
