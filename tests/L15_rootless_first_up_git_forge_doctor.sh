#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L15 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd python3

work_dir="${REPO_ROOT}/.runtime/test-first-up-git-forge-$$"
runtime_root="${work_dir}/runtime-root"
env_file="${work_dir}/env.generated.sh"
output_file="${work_dir}/first-up.out"
project="agentic-first-up-forgejo-$$"
base_port="$((23000 + ($$ % 1000) * 20))"

cleanup() {
  set +e
  if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
    for compose_file in \
      "${REPO_ROOT}/compose/compose.rag.yml" \
      "${REPO_ROOT}/compose/compose.obs.yml" \
      "${REPO_ROOT}/compose/compose.ui.yml" \
      "${REPO_ROOT}/compose/compose.agents.yml" \
      "${REPO_ROOT}/compose/compose.core.yml"; do
      docker compose --project-name "${project}" -f "${compose_file}" down --remove-orphans >/dev/null 2>&1 || true
    done
  fi
  rm -rf "${work_dir}"
}
trap cleanup EXIT

mkdir -p "${work_dir}"

cat >"${env_file}" <<EOF
export AGENTIC_PROFILE='rootless-dev'
export AGENTIC_ROOT='${runtime_root}'
export AGENTIC_COMPOSE_PROJECT='${project}'
export AGENTIC_NETWORK='${project}'
export AGENTIC_LLM_NETWORK='${project}-llm'
export AGENTIC_EGRESS_NETWORK='${project}-egress'
export AGENTIC_SKIP_AGENT_IMAGE_BUILD='1'
export AGENTIC_SKIP_CORE_IMAGE_BUILD='1'
export AGENTIC_SKIP_OPTIONAL_IMAGE_BUILD='1'
export AGENTIC_OLLAMA_GPU_EXPECTED='0'
export GATE_ENABLE_TEST_MODE='1'
export OLLAMA_HOST_PORT='$((base_port + 1))'
export OPENWEBUI_HOST_PORT='$((base_port + 2))'
export OPENHANDS_HOST_PORT='$((base_port + 3))'
export COMFYUI_HOST_PORT='$((base_port + 4))'
export PROMETHEUS_HOST_PORT='$((base_port + 5))'
export GRAFANA_HOST_PORT='$((base_port + 6))'
export LOKI_HOST_PORT='$((base_port + 7))'
export GIT_FORGE_HOST_PORT='$((base_port + 8))'
export GIT_FORGE_SSH_HOST_PORT='$((base_port + 9))'
export OPENCLAW_WEBHOOK_HOST_PORT='$((base_port + 10))'
export OPENCLAW_GATEWAY_HOST_PORT='$((base_port + 11))'
export OPENCLAW_RELAY_HOST_PORT='$((base_port + 12))'
EOF

if ! AGENTIC_ONBOARD_OUTPUT="${env_file}" "${agent_bin}" first-up >"${output_file}" 2>&1; then
  tail -n 120 "${output_file}" >&2 || true
  fail "rootless-dev first-up did not complete through Forgejo bootstrap and doctor"
fi

grep -Fq "first-up step=doctor" "${output_file}" \
  || fail "first-up output must include the doctor step"
grep -Fq "first-up completed" "${output_file}" \
  || fail "first-up must complete after doctor"

bootstrap_state="${runtime_root}/optional/git/bootstrap/git-forge-bootstrap.json"
[[ -s "${bootstrap_state}" ]] || fail "git-forge bootstrap state missing after first-up: ${bootstrap_state}"

python3 - "${bootstrap_state}" "${project}" <<'PY' \
  || fail "git-forge bootstrap state does not match the first-up compose project and SSH contract"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload.get("compose_project") == sys.argv[2]
assert payload.get("shared_repository") == "shared-workbench"
assert payload.get("reference_repository") == "eight-queens-agent-e2e"
ssh = payload.get("ssh_contract") or {}
assert ssh.get("host") == "optional-forgejo"
assert str(ssh.get("port")) == "2222"
paths = ssh.get("managed_paths") or {}
assert paths.get("codex") == "/state/home/.ssh"
assert paths.get("openhands") == "/.openhands/home/.ssh"
assert paths.get("comfyui") == "/comfyui/user/.ssh"
PY

# shellcheck disable=SC1090
source "${env_file}"
"${agent_bin}" doctor >/tmp/agent-l15-doctor.out 2>&1 \
  || {
    tail -n 120 /tmp/agent-l15-doctor.out >&2 || true
    fail "doctor must stay green immediately after rootless-dev first-up"
  }

ok "L15_rootless_first_up_git_forge_doctor passed"
