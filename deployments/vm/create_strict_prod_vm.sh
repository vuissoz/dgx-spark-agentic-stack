#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

VM_NAME="${AGENTIC_VM_NAME:-agentic-strict-prod}"
VM_CPUS="${AGENTIC_VM_CPUS:-8}"
VM_MEMORY="${AGENTIC_VM_MEMORY:-24G}"
VM_DISK="${AGENTIC_VM_DISK:-160G}"
VM_IMAGE="${AGENTIC_VM_IMAGE:-24.04}"
VM_WORKSPACE_PATH="${AGENTIC_VM_WORKSPACE_PATH:-/home/ubuntu/dgx-spark-agentic-stack}"
REUSE_EXISTING=0
REQUIRE_GPU=0
SKIP_BOOTSTRAP=0
MOUNT_REPO=1
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  deployments/vm/create_strict_prod_vm.sh [options]

Options:
  --name <vm-name>           VM name (default: agentic-strict-prod)
  --cpus <int>               Number of vCPUs (default: 8)
  --memory <size>            VM RAM (default: 24G)
  --disk <size>              VM disk size (default: 160G)
  --image <image>            Multipass image/release (default: 24.04)
  --workspace-path <path>    Mount point inside VM (default: /home/ubuntu/dgx-spark-agentic-stack)
  --reuse-existing           Reuse/start VM if already present
  --mount-repo               Mount current repo into the VM (default)
  --no-mount-repo            Do not mount current repo
  --require-gpu              Fail if GPU is not visible with nvidia-smi in VM
  --skip-bootstrap           Skip package/bootstrap actions inside VM
  --dry-run                  Print planned actions without creating VM
  -h, --help

Examples:
  ./deployments/vm/create_strict_prod_vm.sh --memory 32G --cpus 12
  ./deployments/vm/create_strict_prod_vm.sh --name dgx-strict --memory 48G --require-gpu
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

validate_int() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be a positive integer: ${value}"
  [[ "${value}" -gt 0 ]] || die "${name} must be greater than 0: ${value}"
}

validate_size() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+[MGT]$ ]] || die "${name} must match <number><M|G|T>, got: ${value}"
}

vm_exists() {
  multipass info "${VM_NAME}" >/dev/null 2>&1
}

vm_state() {
  multipass info "${VM_NAME}" 2>/dev/null | awk '/^[[:space:]]*State:[[:space:]]+/ {print $2; exit}'
}

cloud_init_file=""
cleanup() {
  if [[ -n "${cloud_init_file}" && -f "${cloud_init_file}" ]]; then
    rm -f "${cloud_init_file}"
  fi
}
trap cleanup EXIT

write_cloud_init() {
  cloud_init_file="$(mktemp)"
  cat >"${cloud_init_file}" <<'EOF'
#cloud-config
package_update: true
package_upgrade: false
runcmd:
  - [bash, -lc, "install -d -m 0750 /srv/agentic /srv/agentic/deployments /srv/agentic/deployments/validation /srv/agentic/deployments/validation/vm-strict-prod"]
  - [bash, -lc, "touch /etc/agentic-vm-created"]
EOF
}

create_vm() {
  write_cloud_init

  info "creating VM '${VM_NAME}' (cpus=${VM_CPUS}, memory=${VM_MEMORY}, disk=${VM_DISK}, image=${VM_IMAGE})"
  multipass launch \
    --name "${VM_NAME}" \
    --cpus "${VM_CPUS}" \
    --memory "${VM_MEMORY}" \
    --disk "${VM_DISK}" \
    --cloud-init "${cloud_init_file}" \
    "${VM_IMAGE}"
}

ensure_vm_running() {
  local state
  state="$(vm_state || true)"
  case "${state}" in
    Running)
      ;;
    Stopped|Suspended)
      info "starting existing VM '${VM_NAME}'"
      multipass start "${VM_NAME}"
      ;;
    *)
      warn "unexpected VM state '${state:-unknown}', attempting start"
      multipass start "${VM_NAME}" || true
      ;;
  esac
}

wait_for_cloud_init() {
  info "waiting for cloud-init to complete in '${VM_NAME}'"
  multipass exec "${VM_NAME}" -- cloud-init status --wait >/dev/null
}

bootstrap_vm() {
  if [[ "${SKIP_BOOTSTRAP}" == "1" ]]; then
    info "skip bootstrap requested (--skip-bootstrap)"
    return 0
  fi

  info "bootstrapping VM packages (docker/git/tmux/jq/iptables)"
  multipass exec "${VM_NAME}" -- bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -qq
    sudo apt-get install -y docker.io git tmux jq iptables curl ca-certificates >/dev/null

    if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
      sudo apt-get install -y docker-compose-v2 >/dev/null
    elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then
      sudo apt-get install -y docker-compose-plugin >/dev/null
    else
      echo "WARN: docker compose plugin package not found in VM repositories" >&2
    fi

    sudo systemctl enable --now docker
    sudo usermod -aG docker "$(id -un)" || true
    sudo install -d -m 0750 /srv/agentic/deployments/validation/vm-strict-prod
  '
}

mount_repo() {
  if [[ "${MOUNT_REPO}" != "1" ]]; then
    return 0
  fi

  info "mounting repo into VM (${REPO_ROOT} -> ${VM_NAME}:${VM_WORKSPACE_PATH})"
  multipass exec "${VM_NAME}" -- mkdir -p "${VM_WORKSPACE_PATH}"
  if ! multipass mount "${REPO_ROOT}" "${VM_NAME}:${VM_WORKSPACE_PATH}" >/tmp/agentic-vm-mount.out 2>&1; then
    if grep -qi "already mounted" /tmp/agentic-vm-mount.out; then
      info "repository is already mounted in '${VM_NAME}'"
    else
      cat /tmp/agentic-vm-mount.out >&2
      warn "repository mount failed; continue with manual transfer if needed"
    fi
  fi
  rm -f /tmp/agentic-vm-mount.out
}

check_gpu() {
  if multipass exec "${VM_NAME}" -- bash -lc 'command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1'; then
    info "GPU visibility check passed (nvidia-smi) in '${VM_NAME}'"
    return 0
  fi

  if [[ "${REQUIRE_GPU}" == "1" ]]; then
    die "GPU is not visible in '${VM_NAME}'. Configure GPU passthrough and NVIDIA drivers, then retry."
  fi

  warn "GPU is not visible in '${VM_NAME}' (nvidia-smi not available)."
  warn "Continue only for CPU-only smoke checks. Use --require-gpu to enforce strict GPU validation."
}

print_dry_run() {
  cat <<EOF
DRY RUN - no changes applied.
provider=multipass
name=${VM_NAME}
cpus=${VM_CPUS}
memory=${VM_MEMORY}
disk=${VM_DISK}
image=${VM_IMAGE}
workspace_path=${VM_WORKSPACE_PATH}
reuse_existing=${REUSE_EXISTING}
mount_repo=${MOUNT_REPO}
require_gpu=${REQUIRE_GPU}
skip_bootstrap=${SKIP_BOOTSTRAP}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || die "missing value for --name"
      VM_NAME="$2"
      shift 2
      ;;
    --cpus)
      [[ $# -ge 2 ]] || die "missing value for --cpus"
      VM_CPUS="$2"
      shift 2
      ;;
    --memory)
      [[ $# -ge 2 ]] || die "missing value for --memory"
      VM_MEMORY="$2"
      shift 2
      ;;
    --disk)
      [[ $# -ge 2 ]] || die "missing value for --disk"
      VM_DISK="$2"
      shift 2
      ;;
    --image)
      [[ $# -ge 2 ]] || die "missing value for --image"
      VM_IMAGE="$2"
      shift 2
      ;;
    --workspace-path)
      [[ $# -ge 2 ]] || die "missing value for --workspace-path"
      VM_WORKSPACE_PATH="$2"
      shift 2
      ;;
    --reuse-existing)
      REUSE_EXISTING=1
      shift
      ;;
    --mount-repo)
      MOUNT_REPO=1
      shift
      ;;
    --no-mount-repo)
      MOUNT_REPO=0
      shift
      ;;
    --require-gpu)
      REQUIRE_GPU=1
      shift
      ;;
    --skip-bootstrap)
      SKIP_BOOTSTRAP=1
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

validate_int "cpus" "${VM_CPUS}"
validate_size "memory" "${VM_MEMORY}"
validate_size "disk" "${VM_DISK}"
[[ -n "${VM_NAME}" ]] || die "name cannot be empty"
[[ "${VM_WORKSPACE_PATH}" == /* ]] || die "workspace path must be absolute: ${VM_WORKSPACE_PATH}"

if [[ "${DRY_RUN}" == "1" ]]; then
  print_dry_run
  exit 0
fi

require_cmd multipass

if vm_exists; then
  if [[ "${REUSE_EXISTING}" == "1" ]]; then
    info "VM '${VM_NAME}' already exists, reusing as requested"
    ensure_vm_running
  else
    die "VM '${VM_NAME}' already exists. Re-run with --reuse-existing to reuse it."
  fi
else
  create_vm
fi

ensure_vm_running
wait_for_cloud_init
bootstrap_vm
mount_repo
check_gpu

cat <<EOF
VM ready: ${VM_NAME}
Attach shell:
  multipass shell ${VM_NAME}

Inside VM, run strict-prod bootstrap:
  export AGENTIC_PROFILE=strict-prod
  cd ${VM_WORKSPACE_PATH}
  sudo ./deployments/bootstrap/init_fs.sh
  sudo ./agent up core
EOF
