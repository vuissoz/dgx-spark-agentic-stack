#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing"

tmpdir="$(mktemp -d)"
bindir="${tmpdir}/bin"
runtime_root="${tmpdir}/runtime"
docker_log="${tmpdir}/docker.log"
mkdir -p "${bindir}" "${runtime_root}"

cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

cat >"${bindir}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${AGENTIC_TEST_DOCKER_LOG:?}"
printf '%s\n' "$*" >>"${log_file}"

if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  exit 1
fi

if [[ "${1:-}" == "ps" ]]; then
  exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
  exit 0
fi

if [[ "${1:-}" == "info" ]]; then
  exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 1
EOF
chmod 0755 "${bindir}/docker"

export PATH="${bindir}:${PATH}"
export AGENTIC_TEST_DOCKER_LOG="${docker_log}"
export AGENTIC_ROOT="${runtime_root}"
export AGENTIC_PROFILE=strict-prod
export COMPOSE_PROFILES=trt
export AGENTIC_SKIP_DOCKER_USER_APPLY=1
export AGENTIC_DISABLE_AUTO_SNAPSHOT=1

"${agent_bin}" up core >/dev/null

grep -Eq 'compose .*--profile trt .* build .* trtllm' "${docker_log}" \
  || fail "agent up core must build the local trtllm image when COMPOSE_PROFILES includes trt"
grep -Eq 'compose .* up .*' "${docker_log}" \
  || fail "agent up core must still perform docker compose up"

ok "F13_trt_profile_local_build passed"
