#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

test_file="${REPO_ROOT}/tests/I2_comfyui_flux_bootstrap.sh"

rg -qF 'empty_hf_token_file="$(mktemp)"' "${test_file}" \
  || fail "I2 must create an explicit empty Hugging Face token file"
rg -qF 'env -u HF_TOKEN "${agent_bin}" comfyui flux-1-dev --download' "${test_file}" \
  || fail "I2 must remove inherited HF_TOKEN before its negative download probe"
rg -qF -- '--hf-token-file "${empty_hf_token_file}"' "${test_file}" \
  || fail "I2 must pass the empty token file to prevent host-token fallback"

bash -n "${test_file}" || fail "I2 must remain valid shell"
ok "I2 Flux bootstrap negative download path is tokenless and deterministic"
