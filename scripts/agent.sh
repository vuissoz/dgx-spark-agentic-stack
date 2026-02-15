#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

usage() {
  cat <<USAGE
Usage:
  agent up <core|agents|ui|obs|rag|optional>
  agent down <core|agents|ui|obs|rag|optional>
  agent ps
  agent logs <service>
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

apply_core_network_policy() {
  if [[ "${AGENTIC_SKIP_DOCKER_USER_APPLY:-0}" == "1" ]]; then
    warn "skipping DOCKER-USER policy apply because AGENTIC_SKIP_DOCKER_USER_APPLY=1"
    return 0
  fi
  if ! "${AGENTIC_REPO_ROOT}/deployments/net/apply_docker_user.sh"; then
    die "failed to apply DOCKER-USER policy; re-run with sudo or set AGENTIC_SKIP_DOCKER_USER_APPLY=1 for local dry-runs"
  fi
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

    if targets_include "core" "${targets[@]}"; then
      ensure_core_runtime
    fi
    if targets_include "agents" "${targets[@]}"; then
      ensure_agents_runtime
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
  ps)
    require_cmd docker
    docker ps \
      --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    ;;
  logs)
    [[ $# -ge 2 ]] || die "Usage: agent logs <service>"
    require_cmd docker
    docker logs --tail "${AGENT_LOG_TAIL:-200}" -f "$2"
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
