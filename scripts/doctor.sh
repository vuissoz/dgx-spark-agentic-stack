#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"
# shellcheck source=tests/lib/common.sh
source "${AGENTIC_REPO_ROOT}/tests/lib/common.sh"

status=0

warn() {
  echo "WARN: $*" >&2
}

doctor_fail() {
  echo "FAIL: $*" >&2
  status=1
}

if ! command -v docker >/dev/null 2>&1; then
  doctor_fail "docker command not found; stack is not ready"
  exit "$status"
fi

if ! docker info >/dev/null 2>&1; then
  doctor_fail "docker daemon unavailable; stack is not ready"
  exit "$status"
fi

if ! assert_no_public_bind; then
  doctor_fail "one or more critical ports are exposed on a non-loopback interface"
fi

running_count="$(docker ps --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" --format '{{.Names}}' | wc -l | tr -d ' ')"
if [[ "$running_count" -eq 0 ]]; then
  doctor_fail "no containers deployed for compose project '${AGENTIC_COMPOSE_PROJECT}' (not ready)"
else
  ok "compose project '${AGENTIC_COMPOSE_PROJECT}' has ${running_count} running container(s)"
fi

if [[ "$status" -ne 0 ]]; then
  warn "doctor result: NOT READY"
else
  ok "doctor result: READY"
fi

exit "$status"
