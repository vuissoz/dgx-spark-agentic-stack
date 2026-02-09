#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_HOST_PREREQS:-0}" == "1" ]]; then
  ok "A1 skipped because AGENTIC_SKIP_HOST_PREREQS=1"
  exit 0
fi

assert_cmd docker
assert_cmd nvidia-smi

docker version >/dev/null 2>&1 || fail "docker version failed"
ok "docker version is available"

docker compose version >/dev/null 2>&1 || fail "docker compose version failed"
ok "docker compose version is available"

nvidia-smi >/dev/null 2>&1 || fail "nvidia-smi failed on host"
ok "host nvidia-smi is available"

if [[ "${AGENTIC_SKIP_GPU_CONTAINER_TEST:-0}" == "1" ]]; then
  ok "GPU container runtime check skipped (AGENTIC_SKIP_GPU_CONTAINER_TEST=1)"
  exit 0
fi

docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1 \
  || fail "containerized nvidia-smi failed; verify NVIDIA Container Toolkit and image availability"
ok "containerized nvidia-smi is available"

ok "A1_host_prereqs passed"
