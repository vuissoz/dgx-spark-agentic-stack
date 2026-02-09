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
  agent doctor
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
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

run_compose_on_targets() {
  local action="$1"
  local target_arg="$2"
  shift 2
  local -a compose_args=()
  local target
  local compose_file

  for target in $(parse_targets "$target_arg"); do
    compose_file="$(stack_to_compose_file "$target")"
    [[ -f "$compose_file" ]] || die "Compose file not found for target '$target': $compose_file"
    compose_args+=("-f" "$compose_file")
  done

  require_cmd docker
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" "${compose_args[@]}" "$action" "$@"
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
    run_compose_on_targets up "$2" -d
    ;;
  down)
    [[ $# -ge 2 ]] || die "Usage: agent down <core|agents|ui|obs|rag|optional>"
    run_compose_on_targets down "$2" --remove-orphans
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
    exec "${SCRIPT_DIR}/doctor.sh"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    die "Unknown command: $cmd"
    ;;
esac
