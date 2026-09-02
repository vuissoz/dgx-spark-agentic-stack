#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/tests/lib/common.sh"
repo="${ROOT}/examples/optional/agent-stack-full-e2e"
python3 -m pytest -q "${repo}/tests" >/tmp/f31-red.out 2>&1 && fail "full reference must begin red"
rg -qF 'FULL_REFERENCE_REPOSITORY = "agent-stack-full-e2e"' "${ROOT}/deployments/optional/git_forge_bootstrap.py" || fail "bootstrap must declare full reference"
rg -qF 'seed_reference_repo(FULL_REFERENCE_REPOSITORY' "${ROOT}/deployments/optional/git_forge_bootstrap.py" || fail "bootstrap must seed full reference"
test -f "${repo}/.agentic/reference-e2e.manifest.json" || fail "missing full reference manifest"
ok "full reference repo is bootstrap-managed and starts red"
