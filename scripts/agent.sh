#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

AGENT_RUNTIME_ENV_FILE="${AGENTIC_ROOT}/deployments/runtime.env"
AGENT_RELEASE_SNAPSHOT_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/releases/snapshot.sh"
AGENT_RELEASE_ROLLBACK_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/releases/rollback.sh"
AGENT_TOOLS=(claude codex opencode)

usage() {
  cat <<USAGE
Usage:
  agent up <core|agents|ui|obs|rag|optional>
  agent down <core|agents|ui|obs|rag|optional>
  agent <claude|codex|opencode> [project]
  agent ls
  agent ps
  agent logs <service>
  agent stop <tool>
  agent update
  agent rollback all <release_id>
  agent test <A|B|C|D|E|F|G|H|I|J|K|all>
  agent doctor [--fix-net]
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

ensure_runtime_env() {
  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${AGENT_RUNTIME_ENV_FILE}"
  chmod 0640 "${AGENT_RUNTIME_ENV_FILE}"

  local -a keys=(
    "AGENTIC_ROOT=${AGENTIC_ROOT}"
    "AGENTIC_COMPOSE_PROJECT=${AGENTIC_COMPOSE_PROJECT}"
    "AGENTIC_NETWORK=${AGENTIC_NETWORK}"
    "AGENTIC_EGRESS_NETWORK=${AGENTIC_EGRESS_NETWORK}"
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

run_compose_on_targets() {
  local action="$1"
  local target_arg="$2"
  shift 2
  local -a compose_args=()
  local compose_file

  local target
  for target in $(parse_targets "$target_arg"); do
    compose_file="$(stack_to_compose_file "$target")"
    [[ -f "$compose_file" ]] || die "Compose file not found for target '$target': $compose_file"
    compose_args+=("-f" "$compose_file")
  done

  require_cmd docker
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" "${compose_args[@]}" "$action" "$@"
}

ensure_core_runtime() {
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
  local release_id="${2:-}"
  ensure_runtime_env

  [[ "${scope}" == "all" ]] || die "Usage: agent rollback all <release_id>"
  [[ -n "${release_id}" ]] || die "Usage: agent rollback all <release_id>"
  [[ -x "${AGENT_RELEASE_ROLLBACK_SCRIPT}" ]] || die "rollback script missing: ${AGENT_RELEASE_ROLLBACK_SCRIPT}"

  "${AGENT_RELEASE_ROLLBACK_SCRIPT}" "${release_id}"
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

cmd="${1:-}"
[[ -n "$cmd" ]] || {
  usage
  exit 1
}

case "$cmd" in
  up)
    [[ $# -ge 2 ]] || die "Usage: agent up <core|agents|ui|obs|rag|optional>"
    target_arg="$2"
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

    run_compose_on_targets up "$target_arg" -d

    if targets_include "core" "${targets[@]}"; then
      apply_core_network_policy
    fi
    ;;
  down)
    [[ $# -ge 2 ]] || die "Usage: agent down <core|agents|ui|obs|rag|optional>"
    target_arg="$2"
    read -r -a targets <<<"$(parse_targets "$target_arg")"
    run_compose_on_targets down "$target_arg" --remove-orphans
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
  update)
    cmd_update
    ;;
  rollback)
    [[ $# -ge 3 ]] || die "Usage: agent rollback all <release_id>"
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
