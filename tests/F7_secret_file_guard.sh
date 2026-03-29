#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F7 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

runtime_root="$(mktemp -d)"
cleanup() {
  rm -rf "${runtime_root}"
}
trap cleanup EXIT

install -d -m 0700 "${runtime_root}/secrets/runtime/git-forge"
mkdir "${runtime_root}/secrets/runtime/git-forge/openclaw.password"

set +e
AGENTIC_PROFILE=rootless-dev \
AGENTIC_ROOT="${runtime_root}" \
  "${REPO_ROOT}/deployments/core/init_runtime.sh" >/tmp/agent-f7-core-init.out 2>&1
rc=$?
set -e

[[ "${rc}" -ne 0 ]] || fail "core init must fail when git-forge secret path is a directory"
grep -q "secret path must be a regular file" /tmp/agent-f7-core-init.out \
  || fail "core init must explain the invalid secret path type"
grep -q "git-forge/openclaw.password" /tmp/agent-f7-core-init.out \
  || fail "core init error must mention the offending secret path"

ok "core init rejects directory-shaped secret paths with an actionable error"
