#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

watchdog="${REPO_ROOT}/scripts/memory_watchdog.sh"
[[ -x "${watchdog}" ]] || fail "memory watchdog is missing or not executable"
! rg -n 'docker\.sock|--privileged' "${watchdog}" >/dev/null || fail "watchdog must not require docker.sock or privileged mode"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"
cat >"${tmp}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  ps) printf 'container-id\n' ;;
  stats) printf 'container-id|100MiB / 100MiB\n' ;;
  inspect)
    [[ "${*: -1}" == "container-id" ]] && printf '104857600\n' || printf '/fake-container\n'
    ;;
  *) exit 0 ;;
esac
EOF
cat >"${tmp}/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
printf '100000, 99000, 1000\n'
EOF
chmod +x "${tmp}/bin/docker" "${tmp}/bin/nvidia-smi"

set +e
PATH="${tmp}/bin:${PATH}" \
AGENTIC_PROFILE=rootless-dev AGENTIC_COMPOSE_PROJECT=watchdog-test \
AGENTIC_ROOT="${tmp}/root" AGENTIC_MEMORY_WATCHDOG_DRY_RUN=1 \
AGENTIC_MEMORY_WATCHDOG_GPU_RESERVED_MB=12000 \
"${watchdog}" --once >"${tmp}/out"
rc=$?
set -e
[[ "${rc}" -eq 0 ]] || fail "watchdog dry-run should complete with a running fake project (rc=${rc})"
grep -q 'gpu_used_percent=99' "${tmp}/out" || fail "watchdog did not report global GPU pressure"
grep -q 'container-memory-warning\|gpu-critical' "${tmp}/root/logs/memory-watchdog.jsonl" || fail "watchdog did not record a resource decision"
ok "F36_memory_watchdog passed"
