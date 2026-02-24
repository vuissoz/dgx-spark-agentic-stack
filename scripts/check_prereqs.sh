#!/usr/bin/env bash
set -euo pipefail

AGENTIC_PROFILE="${AGENTIC_PROFILE:-strict-prod}"

case "${AGENTIC_PROFILE}" in
  strict-prod|rootless-dev) ;;
  *)
    echo "WARN: unknown AGENTIC_PROFILE='${AGENTIC_PROFILE}', using strict-prod checks"
    AGENTIC_PROFILE="strict-prod"
    ;;
esac

required_failures=0
warning_count=0

ok() {
  printf '[OK]   %s\n' "$1"
}

warn() {
  warning_count=$((warning_count + 1))
  printf '[WARN] %s\n' "$1"
}

fail() {
  required_failures=$((required_failures + 1))
  printf '[FAIL] %s\n' "$1"
}

check_cmd() {
  local name="$1"
  local required="$2"
  local hint="$3"

  if command -v "${name}" >/dev/null 2>&1; then
    ok "command '${name}' is available"
  else
    if [[ "${required}" == "1" ]]; then
      fail "command '${name}' is missing (${hint})"
    else
      warn "command '${name}' is missing (${hint})"
    fi
  fi
}

check_nvidia_docker_support() {
  local runtimes_json cdi_dirs_json
  local smoke_image="${AGENTIC_NVIDIA_SMOKE_IMAGE:-nvidia/cuda:12.2.0-base-ubuntu22.04}"

  runtimes_json="$(docker info --format '{{json .Runtimes}}' 2>/dev/null || true)"
  if printf '%s\n' "${runtimes_json}" | grep -q '"nvidia"'; then
    ok "nvidia runtime is registered in Docker (NVIDIA Container Toolkit)"
    return 0
  fi

  if docker run --rm --gpus all "${smoke_image}" nvidia-smi >/dev/null 2>&1; then
    ok "GPU container smoke test works via '--gpus all' (runtime/CDI path)"
    return 0
  fi

  cdi_dirs_json="$(docker info --format '{{json .CDISpecDirs}}' 2>/dev/null || true)"
  if [[ -n "${cdi_dirs_json}" && "${cdi_dirs_json}" != "null" && "${cdi_dirs_json}" != "[]" ]]; then
    fail "nvidia runtime not listed and GPU smoke test failed (CDI dirs: ${cdi_dirs_json}); verify NVIDIA Container Toolkit/CDI wiring"
  else
    fail "nvidia Docker support not detected and GPU smoke test failed (install/configure NVIDIA Container Toolkit)"
  fi
}

echo "Checking prerequisites (profile=${AGENTIC_PROFILE})"

check_cmd "docker" "1" "install Docker Engine"
if command -v docker >/dev/null 2>&1; then
  if docker version >/dev/null 2>&1; then
    ok "docker daemon is reachable"
  else
    fail "docker daemon is not reachable (verify service status and permissions)"
  fi

  if docker compose version >/dev/null 2>&1; then
    ok "docker compose v2 is available"
  else
    fail "docker compose v2 is missing (install Docker Compose plugin)"
  fi

  check_nvidia_docker_support
fi

if command -v nvidia-smi >/dev/null 2>&1; then
  if nvidia-smi >/dev/null 2>&1; then
    ok "nvidia-smi works on host"
  else
    fail "nvidia-smi is installed but failed (verify driver/GPU availability)"
  fi
else
  fail "command 'nvidia-smi' is missing (install NVIDIA driver/toolkit)"
fi

check_cmd "multipass" "0" "install Multipass if you use 'agent vm create', 'agent vm test', or 'agent vm cleanup'"

if [[ "${AGENTIC_PROFILE}" == "strict-prod" ]]; then
  check_cmd "iptables" "1" "install iptables/nftables compat package for DOCKER-USER rules"
else
  check_cmd "iptables" "0" "recommended in strict-prod for DOCKER-USER enforcement"
fi

if [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]]; then
  check_cmd "setfacl" "0" "install package 'acl' for Squid log ACL management"
else
  check_cmd "setfacl" "0" "optional; package 'acl' provides setfacl/getfacl"
fi

if [[ "${required_failures}" -gt 0 ]]; then
  printf '\nResult: FAIL (%d required check(s) failed, %d warning(s)).\n' "${required_failures}" "${warning_count}"
  exit 1
fi

printf '\nResult: OK (0 required failure, %d warning(s)).\n' "${warning_count}"
