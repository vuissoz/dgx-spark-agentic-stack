#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L3 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"
assert_cmd docker

suffix="l3-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"
export AGENTIC_STACK_ALL_TARGETS="optional"
export AGENTIC_CLEANUP_EXPORT_DIR="${REPO_ROOT}/.runtime/${suffix}-exports"
export AGENTIC_AGENT_BASE_IMAGE="agentic/l3-cleanup-${suffix}:local"
export AGENTIC_OLLAMA_MODELS_LINK="${REPO_ROOT}/.runtime/${suffix}-ollama-models-link"
ollama_models_target="${REPO_ROOT}/.runtime/${suffix}-ollama-models-target"

outside_root="${REPO_ROOT}/.runtime/${suffix}-outside"
outside_marker="${outside_root}/keep/me.txt"
symlink_path="${AGENTIC_ROOT}/symlink-outside"

cleanup() {
  AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" down optional >/tmp/agent-l3-down.out 2>&1 || true
  docker network rm "${AGENTIC_EGRESS_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_NETWORK}" >/dev/null 2>&1 || true
  if [[ -d "${AGENTIC_ROOT}" ]]; then
    find "${AGENTIC_ROOT}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${AGENTIC_ROOT}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
  fi
  if [[ -d "${AGENTIC_CLEANUP_EXPORT_DIR}" ]]; then
    find "${AGENTIC_CLEANUP_EXPORT_DIR}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${AGENTIC_CLEANUP_EXPORT_DIR}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${AGENTIC_CLEANUP_EXPORT_DIR}" >/dev/null 2>&1 || true
  fi
  if [[ -d "${outside_root}" ]]; then
    find "${outside_root}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${outside_root}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${outside_root}" >/dev/null 2>&1 || true
  fi
  rm -f "${AGENTIC_OLLAMA_MODELS_LINK}" >/dev/null 2>&1 || true
  if [[ -d "${ollama_models_target}" ]]; then
    find "${ollama_models_target}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${ollama_models_target}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${ollama_models_target}" >/dev/null 2>&1 || true
  fi
  docker image rm -f "${AGENTIC_AGENT_BASE_IMAGE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create --driver bridge --internal "${AGENTIC_NETWORK}" >/dev/null
docker network create --driver bridge "${AGENTIC_EGRESS_NETWORK}" >/dev/null

docker build -t "${AGENTIC_AGENT_BASE_IMAGE}" - <<'EOF' >/tmp/agent-l3-image-build.out
FROM busybox:1.36
RUN true
EOF
docker image inspect "${AGENTIC_AGENT_BASE_IMAGE}" >/dev/null \
  || fail "failed to build cleanup image fixture ${AGENTIC_AGENT_BASE_IMAGE}"

"${REPO_ROOT}/deployments/bootstrap/init_fs.sh"
AGENTIC_SKIP_OPTIONAL_GATING=1 "${agent_bin}" up optional >/tmp/agent-l3-up.out \
  || fail "unable to start optional stack for cleanup test"

sentinel_cid="$(require_service_container optional-sentinel)" || exit 1
wait_for_container_ready "${sentinel_cid}" 60 || fail "optional-sentinel did not become ready"

touch "${AGENTIC_ROOT}/cleanup-marker.txt"
mkdir -p "${AGENTIC_ROOT}/nested/state"
touch "${AGENTIC_ROOT}/nested/state/value.txt"
mkdir -p "$(dirname "${outside_marker}")"
printf 'keep-me\n' >"${outside_marker}"
ln -s "${outside_root}" "${symlink_path}"
mkdir -p "${ollama_models_target}"
ln -s "${ollama_models_target}" "${AGENTIC_OLLAMA_MODELS_LINK}"

printf 'y\nCLEAN\nremove-every-thing\n' | "${agent_bin}" rootless-dev cleanup >/tmp/agent-l3-cleanup.out \
  || fail "agent rootless-dev cleanup interactive flow failed"

grep -q 'cleanup completed root=' /tmp/agent-l3-cleanup.out \
  || fail "cleanup output must include completion marker"

[[ -d "${AGENTIC_ROOT}" ]] || fail "cleanup must preserve runtime root directory"
if find "${AGENTIC_ROOT}" -mindepth 1 -print -quit | grep -q .; then
  fail "cleanup must remove all files under runtime root"
fi
[[ -f "${outside_marker}" ]] || fail "cleanup must not follow symlink target outside runtime root"
[[ ! -e "${symlink_path}" ]] || fail "cleanup must remove symlink entry under runtime root"
[[ ! -e "${AGENTIC_OLLAMA_MODELS_LINK}" ]] || fail "cleanup must unlink AGENTIC_OLLAMA_MODELS_LINK in rootless-dev"
[[ -d "${ollama_models_target}" ]] || fail "cleanup must not delete ollama models target directory outside AGENTIC_ROOT"

backup_count="$(find "${AGENTIC_CLEANUP_EXPORT_DIR}" -maxdepth 1 -type f -name '*.tar.gz' | wc -l | tr -d ' ')"
[[ "${backup_count}" -ge 1 ]] || fail "cleanup must export a backup archive when backup is requested"

[[ -z "$(service_container_id optional-sentinel)" ]] || fail "optional-sentinel must be stopped by cleanup"
if docker image inspect "${AGENTIC_AGENT_BASE_IMAGE}" >/dev/null 2>&1; then
  fail "cleanup must remove local docker images linked to the stack"
fi

ok "L3_cleanup passed"
