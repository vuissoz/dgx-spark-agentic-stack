#!/usr/bin/env bash

agentic_repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${script_dir}/../.." && pwd
}

AGENTIC_REPO_ROOT="$(agentic_repo_root)"
AGENTIC_PROFILE="${AGENTIC_PROFILE:-strict-prod}"

case "${AGENTIC_PROFILE}" in
  strict-prod|rootless-dev)
    ;;
  *)
    echo "ERROR: invalid AGENTIC_PROFILE='${AGENTIC_PROFILE}' (expected strict-prod or rootless-dev)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

if [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]]; then
  AGENTIC_ROOT="${AGENTIC_ROOT:-${HOME}/.local/share/agentic}"
  AGENTIC_COMPOSE_PROJECT="${AGENTIC_COMPOSE_PROJECT:-agentic-dev}"
  AGENTIC_NETWORK="${AGENTIC_NETWORK:-agentic-dev}"
  AGENTIC_EGRESS_NETWORK="${AGENTIC_EGRESS_NETWORK:-agentic-dev-egress}"
  AGENTIC_DOCKER_USER_CHAIN="${AGENTIC_DOCKER_USER_CHAIN:-AGENTIC-DOCKER-USER}"

  AGENTIC_SKIP_DOCKER_USER_APPLY="${AGENTIC_SKIP_DOCKER_USER_APPLY:-1}"
  AGENTIC_SKIP_DOCKER_USER_CHECK="${AGENTIC_SKIP_DOCKER_USER_CHECK:-1}"
  AGENTIC_SKIP_DOCTOR_PROXY_CHECK="${AGENTIC_SKIP_DOCTOR_PROXY_CHECK:-1}"
else
  AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
  AGENTIC_COMPOSE_PROJECT="${AGENTIC_COMPOSE_PROJECT:-agentic}"
  AGENTIC_NETWORK="${AGENTIC_NETWORK:-agentic}"
  AGENTIC_EGRESS_NETWORK="${AGENTIC_EGRESS_NETWORK:-agentic-egress}"
  AGENTIC_DOCKER_USER_CHAIN="${AGENTIC_DOCKER_USER_CHAIN:-AGENTIC-DOCKER-USER}"
fi

AGENTIC_COMPOSE_DIR="${AGENTIC_COMPOSE_DIR:-${AGENTIC_REPO_ROOT}/compose}"
AGENTIC_TEST_DIR="${AGENTIC_TEST_DIR:-${AGENTIC_REPO_ROOT}/tests}"
