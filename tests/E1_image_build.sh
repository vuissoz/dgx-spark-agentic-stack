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

ok "E1_image_build passed"
