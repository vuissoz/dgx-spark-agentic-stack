#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

work_dir="${REPO_ROOT}/.runtime/test-first-up-$$"
env_file="${work_dir}/env.generated.sh"
runtime_root="${work_dir}/runtime-root"
output_file="${work_dir}/first-up.out"
output_no_env_file="${work_dir}/first-up-no-env.out"
invalid_file="${work_dir}/first-up-invalid.out"

trap 'rm -rf "${work_dir}"' EXIT
mkdir -p "${work_dir}"

cat >"${env_file}" <<EOF
export AGENTIC_PROFILE='rootless-dev'
export AGENTIC_ROOT='${runtime_root}'
export AGENTIC_COMPOSE_PROJECT='agentic-first-up-test'
EOF

if ! AGENTIC_PROFILE=strict-prod AGENTIC_ONBOARD_OUTPUT="${env_file}" \
  "${agent_bin}" first-up --dry-run >"${output_file}" 2>&1; then
  cat "${output_file}" >&2 || true
  fail "agent first-up --dry-run failed"
fi

grep -Fq "first-up loaded_env=${env_file}" "${output_file}" \
  || fail "first-up should load AGENTIC_ONBOARD_OUTPUT when present"

for step in profile init-fs up-core up-baseline doctor; do
  grep -Fq "first-up step=${step}" "${output_file}" \
    || fail "first-up dry-run output is missing step '${step}'"
done

grep -Fq "first-up completed (dry-run)" "${output_file}" \
  || fail "first-up dry-run completion message is missing"

[[ ! -d "${runtime_root}" ]] \
  || fail "first-up --dry-run must not create runtime root directory"

if ! AGENTIC_PROFILE=strict-prod AGENTIC_ONBOARD_OUTPUT="${env_file}" \
  "${agent_bin}" first-up --no-env --dry-run >"${output_no_env_file}" 2>&1; then
  cat "${output_no_env_file}" >&2 || true
  fail "agent first-up --no-env --dry-run failed"
fi

if grep -Fq "first-up loaded_env=" "${output_no_env_file}"; then
  fail "first-up --no-env must not source the env file"
fi

if "${agent_bin}" first-up --does-not-exist >"${invalid_file}" 2>&1; then
  cat "${invalid_file}" >&2 || true
  fail "agent first-up should reject unknown flags"
fi

grep -Fq "Unknown first-up argument" "${invalid_file}" \
  || fail "first-up invalid-argument error should be explicit"

ok "F9_first_up_command passed"
