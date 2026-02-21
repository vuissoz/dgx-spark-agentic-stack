#!/usr/bin/env bash
set -euo pipefail

VM_NAME="${AGENTIC_VM_NAME:-agentic-strict-prod}"
VM_WORKSPACE_PATH="${AGENTIC_VM_WORKSPACE_PATH:-/home/ubuntu/dgx-spark-agentic-stack}"
TEST_SELECTORS_RAW="${AGENTIC_VM_TEST_SELECTORS:-A,B,C,D,E,F,G,H,I,J,K}"
VALIDATION_ROOT="/srv/agentic/deployments/validation/vm-strict-prod"
REQUIRE_GPU=1
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  deployments/vm/test_strict_prod_vm.sh [options]

Options:
  --name <vm-name>             VM name (default: agentic-strict-prod)
  --workspace-path <path>      Repository path inside the VM (default: /home/ubuntu/dgx-spark-agentic-stack)
  --test-selectors <csv>       Campaign selectors (A..L or all, default: A,B,C,D,E,F,G,H,I,J,K)
  --require-gpu                Fail if nvidia-smi is unavailable in VM (default)
  --allow-no-gpu               Continue with degraded checks and explicit blocked markers
  --dry-run                    Print planned actions only
  -h, --help

Examples:
  ./deployments/vm/test_strict_prod_vm.sh --name agentic-strict-prod
  ./deployments/vm/test_strict_prod_vm.sh --name agentic-strict-prod --allow-no-gpu
  ./deployments/vm/test_strict_prod_vm.sh --test-selectors A,B,C,F,G,J,K
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

info() {
  echo "INFO: $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

vm_exists() {
  multipass info "${VM_NAME}" >/dev/null 2>&1
}

vm_state() {
  multipass info "${VM_NAME}" 2>/dev/null | awk '/^[[:space:]]*State:[[:space:]]+/ {print $2; exit}'
}

ensure_vm_running() {
  local state
  state="$(vm_state || true)"
  case "${state}" in
    Running)
      ;;
    Stopped|Suspended)
      info "starting VM '${VM_NAME}'"
      multipass start "${VM_NAME}"
      ;;
    *)
      warn "unexpected VM state '${state:-unknown}', attempting start"
      multipass start "${VM_NAME}" || true
      ;;
  esac
}

normalize_selectors() {
  local raw="$1"
  local token selector
  local -A seen=()
  local -a normalized=()

  raw="${raw//,/ }"
  for token in ${raw}; do
    case "${token}" in
      all)
        for selector in A B C D E F G H I J K L; do
          if [[ -z "${seen[${selector}]:-}" ]]; then
            normalized+=("${selector}")
            seen["${selector}"]=1
          fi
        done
        ;;
      A|B|C|D|E|F|G|H|I|J|K|L)
        if [[ -z "${seen[${token}]:-}" ]]; then
          normalized+=("${token}")
          seen["${token}"]=1
        fi
        ;;
      *)
        die "Invalid test selector '${token}'. Expected A..L or all."
        ;;
    esac
  done

  [[ "${#normalized[@]}" -gt 0 ]] || die "No test selectors resolved from '${1}'"
  printf '%s\n' "${normalized[@]}"
}

join_csv() {
  local -a parts=("$@")
  local joined=""
  local item
  for item in "${parts[@]}"; do
    if [[ -z "${joined}" ]]; then
      joined="${item}"
    else
      joined="${joined},${item}"
    fi
  done
  printf '%s\n' "${joined}"
}

print_dry_run() {
  cat <<EOF
DRY RUN - no changes applied.
provider=multipass
name=${VM_NAME}
workspace_path=${VM_WORKSPACE_PATH}
test_selectors=${TEST_SELECTORS_CANONICAL}
require_gpu=${REQUIRE_GPU}
validation_root=${VALIDATION_ROOT}
planned_steps=bootstrap,up_core,up_stacks,doctor,update,rollback,tests,doctor_final,ps_final
EOF
}

run_remote_validation() {
  multipass exec "${VM_NAME}" -- bash -s -- \
    "${VM_WORKSPACE_PATH}" \
    "${TEST_SELECTORS_CANONICAL}" \
    "${REQUIRE_GPU}" \
    "${VALIDATION_ROOT}" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

vm_workspace_path="$1"
test_selectors="$2"
require_gpu="$3"
validation_root="$4"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

info() {
  echo "INFO: $*"
}

[[ -d "${vm_workspace_path}" ]] || die "workspace path does not exist in VM: ${vm_workspace_path}"
cd "${vm_workspace_path}"
[[ -x "./agent" ]] || die "missing executable agent entrypoint at ${vm_workspace_path}/agent"
[[ -x "./deployments/bootstrap/init_fs.sh" ]] || die "missing bootstrap script at ${vm_workspace_path}/deployments/bootstrap/init_fs.sh"

gpu_available=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  gpu_available=1
fi

stack_targets="agents,ui,obs,rag"
skip_host_prereqs=0
skip_dcgm_check=0
skip_h_tests=0
skip_i_tests=0

if [[ "${gpu_available}" != "1" ]]; then
  if [[ "${require_gpu}" == "1" ]]; then
    die "GPU is not visible in VM and --require-gpu is enabled"
  fi
  warn "GPU is unavailable in VM; running degraded campaign without UI stack and GPU-bound checks"
  stack_targets="agents,obs,rag"
  skip_host_prereqs=1
  skip_dcgm_check=1
  skip_h_tests=1
  skip_i_tests=1
fi

ts="$(date -u +%Y%m%dT%H%M%SZ)"
proof_dir="${validation_root}/${ts}"
sudo install -d -m 0750 "${validation_root}" "${proof_dir}"

run_capture() {
  local log_path="$1"
  shift
  sudo env AGENTIC_PROFILE=strict-prod "$@" 2>&1 | sudo tee "${log_path}" >/dev/null
}

info "strict-prod bootstrap"
run_capture "${proof_dir}/bootstrap-init-fs.log" ./deployments/bootstrap/init_fs.sh

info "starting core stack"
run_capture "${proof_dir}/agent-up-core.log" ./agent up core

info "starting stack targets ${stack_targets}"
run_capture "${proof_dir}/agent-up-targets.log" ./agent up "${stack_targets}"

info "running initial doctor"
run_capture "${proof_dir}/agent-doctor-initial.log" ./agent doctor

info "running update"
run_capture "${proof_dir}/agent-update.log" ./agent update
release_id="$(sudo sed -n 's/^update completed, release=//p' "${proof_dir}/agent-update.log" | tail -n 1)"
[[ -n "${release_id}" ]] || die "unable to extract release id from agent update output"
printf '%s\n' "${release_id}" | sudo tee "${proof_dir}/release_update.id" >/dev/null

info "running rollback to ${release_id}"
run_capture "${proof_dir}/agent-rollback.log" ./agent rollback all "${release_id}"
printf '%s\n' "${release_id}" | sudo tee "${proof_dir}/release_rollback_target.id" >/dev/null

sudo sh -c ": > '${proof_dir}/tests.summary'"
IFS=',' read -r -a selectors <<<"${test_selectors}"
for selector in "${selectors[@]}"; do
  selector="${selector// /}"
  [[ -n "${selector}" ]] || continue
  info "running test selector ${selector}"
  if run_capture "${proof_dir}/agent-test-${selector}.log" env \
    AGENTIC_SKIP_HOST_PREREQS="${skip_host_prereqs}" \
    AGENTIC_SKIP_DCGM_CHECK="${skip_dcgm_check}" \
    AGENTIC_SKIP_H_TESTS="${skip_h_tests}" \
    AGENTIC_SKIP_I_TESTS="${skip_i_tests}" \
    ./agent test "${selector}"; then
    printf '%s=pass\n' "${selector}" | sudo tee -a "${proof_dir}/tests.summary" >/dev/null
  else
    printf '%s=fail\n' "${selector}" | sudo tee -a "${proof_dir}/tests.summary" >/dev/null
    die "test selector '${selector}' failed"
  fi
done

info "running final doctor and ps"
run_capture "${proof_dir}/agent-doctor-final.log" ./agent doctor
run_capture "${proof_dir}/agent-ps-final.log" ./agent ps

meta_tmp="$(mktemp)"
{
  printf 'profile=strict-prod\n'
  printf 'workspace_path=%s\n' "${vm_workspace_path}"
  printf 'validation_dir=%s\n' "${proof_dir}"
  printf 'stack_targets=%s\n' "${stack_targets}"
  printf 'test_selectors=%s\n' "${test_selectors}"
  printf 'require_gpu=%s\n' "${require_gpu}"
  printf 'gpu_available=%s\n' "${gpu_available}"
  printf 'release_update=%s\n' "${release_id}"
  printf 'created_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"${meta_tmp}"
sudo install -m 0640 "${meta_tmp}" "${proof_dir}/campaign.meta"
rm -f "${meta_tmp}"

if [[ "${gpu_available}" == "1" ]]; then
  cat <<'EOF' | sudo tee "${proof_dir}/gpu-status.txt" >/dev/null
gpu_available=1
status=ok
notes=full stack validation path executed
EOF
else
  cat <<EOF | sudo tee "${proof_dir}/gpu-status.txt" >/dev/null
gpu_available=0
status=degraded
reason=nvidia-smi unavailable in VM; GPU-coupled checks were skipped without changing security controls
skipped_stack_targets=ui
skipped_env=AGENTIC_SKIP_HOST_PREREQS=${skip_host_prereqs},AGENTIC_SKIP_DCGM_CHECK=${skip_dcgm_check},AGENTIC_SKIP_H_TESTS=${skip_h_tests},AGENTIC_SKIP_I_TESTS=${skip_i_tests}
EOF
fi

printf 'validation_dir=%s\n' "${proof_dir}"
printf 'release_update=%s\n' "${release_id}"
printf 'stack_targets=%s\n' "${stack_targets}"
printf 'test_selectors=%s\n' "${test_selectors}"
REMOTE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || die "missing value for --name"
      VM_NAME="$2"
      shift 2
      ;;
    --workspace-path)
      [[ $# -ge 2 ]] || die "missing value for --workspace-path"
      VM_WORKSPACE_PATH="$2"
      shift 2
      ;;
    --test-selectors)
      [[ $# -ge 2 ]] || die "missing value for --test-selectors"
      TEST_SELECTORS_RAW="$2"
      shift 2
      ;;
    --require-gpu)
      REQUIRE_GPU=1
      shift
      ;;
    --allow-no-gpu)
      REQUIRE_GPU=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${VM_NAME}" ]] || die "name cannot be empty"
[[ "${VM_WORKSPACE_PATH}" == /* ]] || die "workspace path must be absolute: ${VM_WORKSPACE_PATH}"

selectors_output="$(normalize_selectors "${TEST_SELECTORS_RAW}")"
mapfile -t TEST_SELECTORS_ARRAY <<<"${selectors_output}"
TEST_SELECTORS_CANONICAL="$(join_csv "${TEST_SELECTORS_ARRAY[@]}")"

if [[ "${DRY_RUN}" == "1" ]]; then
  print_dry_run
  exit 0
fi

require_cmd multipass

vm_exists || die "VM '${VM_NAME}' does not exist. Create it first with: ./agent vm create --name ${VM_NAME}"
ensure_vm_running
run_remote_validation
