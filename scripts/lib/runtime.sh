#!/usr/bin/env bash

agentic_repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${script_dir}/../.." && pwd
}

AGENTIC_REPO_ROOT="$(agentic_repo_root)"
AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
AGENTIC_COMPOSE_PROJECT="${AGENTIC_COMPOSE_PROJECT:-agentic}"
AGENTIC_COMPOSE_DIR="${AGENTIC_COMPOSE_DIR:-${AGENTIC_REPO_ROOT}/compose}"
AGENTIC_TEST_DIR="${AGENTIC_TEST_DIR:-${AGENTIC_REPO_ROOT}/tests}"
AGENTIC_NETWORK="${AGENTIC_NETWORK:-agentic}"
AGENTIC_EGRESS_NETWORK="${AGENTIC_EGRESS_NETWORK:-agentic-egress}"
AGENTIC_DOCKER_USER_CHAIN="${AGENTIC_DOCKER_USER_CHAIN:-AGENTIC-DOCKER-USER}"
