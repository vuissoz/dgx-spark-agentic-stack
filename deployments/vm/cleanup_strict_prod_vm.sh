#!/usr/bin/env bash
set -euo pipefail

VM_NAME="${AGENTIC_VM_NAME:-agentic-strict-prod}"
FORCE=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  deployments/vm/cleanup_strict_prod_vm.sh [options]

Options:
  --name <vm-name>      VM name to cleanup (default: agentic-strict-prod)
  --yes                 Skip interactive confirmation
  --dry-run             Print planned actions only
  -h, --help

Examples:
  ./deployments/vm/cleanup_strict_prod_vm.sh --name agentic-strict-prod
  ./deployments/vm/cleanup_strict_prod_vm.sh --name agentic-strict-prod --yes
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

print_dry_run() {
  cat <<EOF
DRY RUN - no changes applied.
provider=multipass
name=${VM_NAME}
force=${FORCE}
planned_steps=stop_if_running,delete
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || die "missing value for --name"
      VM_NAME="$2"
      shift 2
      ;;
    --yes)
      FORCE=1
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

if [[ "${DRY_RUN}" == "1" ]]; then
  print_dry_run
  exit 0
fi

require_cmd multipass

if ! vm_exists; then
  info "VM '${VM_NAME}' does not exist; nothing to cleanup."
  exit 0
fi

if [[ "${FORCE}" != "1" ]]; then
  printf "Cleanup will stop and delete VM '%s'. Type %s to continue: " "${VM_NAME}" "${VM_NAME}"
  IFS= read -r confirmation || die "cleanup aborted: confirmation not provided"
  [[ "${confirmation}" == "${VM_NAME}" ]] || die "cleanup aborted: confirmation token mismatch"
fi

state="$(vm_state || true)"
case "${state}" in
  Running)
    info "stopping VM '${VM_NAME}'"
    multipass stop "${VM_NAME}"
    ;;
  Stopped|Suspended|Deleted)
    info "VM '${VM_NAME}' state is '${state}', stop not required"
    ;;
  *)
    warn "unexpected VM state '${state:-unknown}', attempting graceful stop"
    multipass stop "${VM_NAME}" >/dev/null 2>&1 || true
    ;;
esac

if [[ "${state}" != "Deleted" ]]; then
  info "deleting VM '${VM_NAME}'"
  multipass delete "${VM_NAME}"
fi

final_state="$(vm_state || true)"
if [[ -z "${final_state}" ]]; then
  final_state="unknown"
fi

if [[ "${final_state}" == "Deleted" ]]; then
  info "VM '${VM_NAME}' is deleted. Use 'multipass purge' manually when you are ready to reclaim disk."
fi

printf 'vm cleanup completed name=%s state=%s\n' "${VM_NAME}" "${final_state}"
