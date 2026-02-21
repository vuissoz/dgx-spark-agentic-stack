#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

wizard_script="${REPO_ROOT}/deployments/bootstrap/onboarding_env.sh"
[[ -x "${wizard_script}" ]] || fail "onboarding wizard is missing or not executable: ${wizard_script}"

work_dir="${REPO_ROOT}/.runtime/test-onboarding-env-$$"
default_env_file="${work_dir}/default.env.generated.sh"
override_env_file="${work_dir}/override.env.generated.sh"
default_log="${work_dir}/default.log"
override_log="${work_dir}/override.log"
non_interactive_env_file="${work_dir}/non-interactive.env.generated.sh"

trap 'rm -rf "${work_dir}"' EXIT
mkdir -p "${work_dir}"

run_default_answers() {
  if ! printf '\n\n\n\n\n\n' \
    | AGENTIC_PROFILE=strict-prod "${wizard_script}" --output "${default_env_file}" >"${default_log}" 2>&1; then
    cat "${default_log}" >&2 || true
    fail "wizard failed with default Enter answers"
  fi
}

run_override_answers() {
  local custom_root="${work_dir}/custom-runtime-root"
  local custom_models="${work_dir}/custom-ollama-models"
  local custom_compose="agentic-ci"
  local custom_network="agentic-ci-net"
  local custom_egress_network="agentic-ci-egress"

  if ! cat <<EOF | AGENTIC_PROFILE=strict-prod "${wizard_script}" --output "${override_env_file}" >"${override_log}" 2>&1
rootless-dev
${custom_root}
${custom_compose}
${custom_network}
${custom_egress_network}
${custom_models}
EOF
  then
    cat "${override_log}" >&2 || true
    fail "wizard failed with overridden answers"
  fi
}

assert_generated_file_baseline() {
  local file_path="$1"
  [[ -s "${file_path}" ]] || fail "generated file is missing or empty: ${file_path}"
  bash -n "${file_path}" || fail "generated file is not valid bash syntax: ${file_path}"

  if grep -Eiq '(secret|token|password|api_key|private_key)' "${file_path}"; then
    fail "generated file must not contain secret-looking keys: ${file_path}"
  fi
}

assert_git_ignored() {
  local file_path="$1"
  local relative_path="${file_path#${REPO_ROOT}/}"
  if [[ "${relative_path}" == "${file_path}" ]]; then
    fail "file path is outside repository: ${file_path}"
  fi

  git -C "${REPO_ROOT}" check-ignore -q "${relative_path}" \
    || fail "generated onboarding file is not git-ignored: ${relative_path}"
}

run_default_answers
assert_generated_file_baseline "${default_env_file}"

grep -q "^export AGENTIC_PROFILE='strict-prod'$" "${default_env_file}" \
  || fail "default profile is not strict-prod"
grep -q "^export AGENTIC_ROOT='/srv/agentic'$" "${default_env_file}" \
  || fail "default AGENTIC_ROOT is not /srv/agentic"
grep -q "^export AGENTIC_COMPOSE_PROJECT='agentic'$" "${default_env_file}" \
  || fail "default AGENTIC_COMPOSE_PROJECT is not agentic"
grep -q "^export AGENTIC_NETWORK='agentic'$" "${default_env_file}" \
  || fail "default AGENTIC_NETWORK is not agentic"
grep -q "^export AGENTIC_EGRESS_NETWORK='agentic-egress'$" "${default_env_file}" \
  || fail "default AGENTIC_EGRESS_NETWORK is not agentic-egress"
grep -q "^export OLLAMA_MODELS_DIR='/srv/agentic/ollama/models'$" "${default_env_file}" \
  || fail "default OLLAMA_MODELS_DIR is not /srv/agentic/ollama/models"

assert_git_ignored "${default_env_file}"
ok "wizard default Enter flow generates expected defaults"

run_override_answers
assert_generated_file_baseline "${override_env_file}"

grep -q "^export AGENTIC_PROFILE='rootless-dev'$" "${override_env_file}" \
  || fail "override profile is not rootless-dev"
grep -q "^export AGENTIC_ROOT='${work_dir}/custom-runtime-root'$" "${override_env_file}" \
  || fail "override AGENTIC_ROOT is not applied"
grep -q "^export AGENTIC_COMPOSE_PROJECT='agentic-ci'$" "${override_env_file}" \
  || fail "override AGENTIC_COMPOSE_PROJECT is not applied"
grep -q "^export AGENTIC_NETWORK='agentic-ci-net'$" "${override_env_file}" \
  || fail "override AGENTIC_NETWORK is not applied"
grep -q "^export AGENTIC_EGRESS_NETWORK='agentic-ci-egress'$" "${override_env_file}" \
  || fail "override AGENTIC_EGRESS_NETWORK is not applied"
grep -q "^export OLLAMA_MODELS_DIR='${work_dir}/custom-ollama-models'$" "${override_env_file}" \
  || fail "override OLLAMA_MODELS_DIR is not applied"

assert_git_ignored "${override_env_file}"
ok "wizard override flow writes custom values"

if ! AGENTIC_PROFILE=strict-prod "${wizard_script}" \
  --non-interactive \
  --profile rootless-dev \
  --root "${work_dir}/ni-root" \
  --compose-project agentic-ni \
  --network agentic-ni-net \
  --egress-network agentic-ni-egress \
  --ollama-models-dir "${work_dir}/ni-models" \
  --output "${non_interactive_env_file}" >/dev/null 2>&1; then
  fail "wizard non-interactive flag mode failed"
fi
assert_generated_file_baseline "${non_interactive_env_file}"
assert_git_ignored "${non_interactive_env_file}"
ok "wizard non-interactive flags mode works"

ok "00_onboarding_env_wizard passed"
