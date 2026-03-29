#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

profile_output="$(COMPOSE_PROFILES='trt,optional-goose' "${agent_bin}" profile)"
printf '%s\n' "${profile_output}" | grep -q '^compose_profiles=trt,optional-goose$' \
  || fail "agent profile must print the effective compose_profiles value"

empty_output="$(env -u COMPOSE_PROFILES "${agent_bin}" profile)"
printf '%s\n' "${empty_output}" | grep -q '^compose_profiles=$' \
  || fail "agent profile must print compose_profiles even when it is empty"

ok "00_profile_compose_profiles passed"
