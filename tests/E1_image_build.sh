#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_E_TESTS:-0}" == "1" ]]; then
  ok "E1 skipped because AGENTIC_SKIP_E_TESTS=1"
  exit 0
fi

assert_cmd docker

image_ref="${AGENTIC_AGENT_BASE_IMAGE_TEST_REF:-agentic/agent-cli-base:e1-test}"
docker build \
  --tag "${image_ref}" \
  --file "${REPO_ROOT}/deployments/images/agent-cli-base/Dockerfile" \
  "${REPO_ROOT}" >/dev/null
ok "agent-cli-base image build succeeded (${image_ref})"

image_user="$(docker image inspect --format '{{.Config.User}}' "${image_ref}")"
[[ -n "${image_user}" && "${image_user}" != "root" && "${image_user}" != "0" ]] \
  || fail "agent-cli-base image user must be non-root (actual='${image_user}')"
ok "agent-cli-base image user is non-root (${image_user})"

timeout 20 docker run --rm --entrypoint bash "${image_ref}" -lc 'command -v tmux git curl >/dev/null' \
  || fail "agent-cli-base image is missing one of: tmux, git, curl"
ok "agent-cli-base image includes tmux/git/curl"

timeout 60 docker run --rm --entrypoint bash "${image_ref}" -lc '
  command -v gcc g++ cmake ninja clang python3 pip3 node npm go rustc cargo nvcc >/dev/null
  nvcc --version >/dev/null
' || fail "agent-cli-base image is missing one of: gcc g++ cmake ninja clang python3 pip3 node npm go rustc cargo nvcc"
ok "agent-cli-base image includes C/C++ + CUDA + multi-language toolchain"

timeout 60 docker run --rm --entrypoint bash "${image_ref}" -lc '
  command -v codex claude opencode pi vibe openhands openclaw hermes >/dev/null
  for cli in codex claude opencode pi vibe openhands openclaw hermes; do
    test -f "/etc/agentic/${cli}-real-path"
    "${cli}" --version >/dev/null 2>&1 || true
  done
' || fail "agent-cli-base image is missing one of: codex claude opencode pi vibe openhands openclaw hermes wrappers"
ok "agent-cli-base image exposes codex/claude/opencode/pi/vibe/openhands/openclaw/hermes commands"

timeout 60 docker run --rm --entrypoint bash "${image_ref}" -lc '
  cat > /tmp/e1-smoke.c <<'"'"'EOF'"'"'
#include <stdio.h>
int main(void) { puts("ok-c"); return 0; }
EOF
  gcc /tmp/e1-smoke.c -o /tmp/e1-smoke-c
  /tmp/e1-smoke-c | grep -q "ok-c"

  cat > /tmp/e1-smoke.cpp <<'"'"'EOF'"'"'
#include <iostream>
int main() { std::cout << "ok-cpp" << std::endl; return 0; }
EOF
  g++ /tmp/e1-smoke.cpp -o /tmp/e1-smoke-cpp
  /tmp/e1-smoke-cpp | grep -q "ok-cpp"

  cat > /tmp/e1-smoke.cu <<'"'"'EOF'"'"'
#include <cuda_runtime.h>
__global__ void noop() {}
int main() { noop<<<1,1>>>(); return 0; }
EOF
  nvcc /tmp/e1-smoke.cu -o /tmp/e1-smoke-cuda
' || fail "agent-cli-base smoke builds failed for C/C++/CUDA toolchains"
ok "agent-cli-base smoke builds succeeded for C/C++/CUDA"

ok "E1_image_build passed"
