#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_I_TESTS:-0}" == "1" ]]; then
  ok "I2 skipped because AGENTIC_SKIP_I_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd python3

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

comfy_cid="$(require_service_container comfyui)" || exit 1
wait_for_container_ready "${comfy_cid}" 180 || fail "comfyui is not ready"

"${agent_bin}" comfyui flux-1-dev --no-egress-check >/tmp/agent-i2-flux.out \
  || fail "agent comfyui flux-1-dev bootstrap command failed"

manifest_path="${AGENTIC_ROOT:-/srv/agentic}/comfyui/models/flux1-dev.manifest.json"
[[ -s "${manifest_path}" ]] || fail "flux manifest is missing: ${manifest_path}"
ok "flux manifest exists"

python3 - "${manifest_path}" <<'PY' || fail "flux manifest content is invalid"
import json
import sys

manifest_path = sys.argv[1]
payload = json.loads(open(manifest_path, "r", encoding="utf-8").read())
files = payload.get("files")
if not isinstance(files, list) or len(files) < 4:
    raise SystemExit("manifest files array is missing or too small")
required_targets = {
    "checkpoints/flux1-dev.safetensors",
    "vae/ae.safetensors",
    "clip/clip_l.safetensors",
    "clip/t5xxl_fp16.safetensors",
}
seen_targets = {item.get("target") for item in files if isinstance(item, dict)}
missing = sorted(required_targets - seen_targets)
if missing:
    raise SystemExit(f"manifest missing required targets: {missing}")
PY
ok "flux manifest contains required Flux.1-dev targets"

for subdir in checkpoints clip vae; do
  [[ -d "${AGENTIC_ROOT:-/srv/agentic}/comfyui/models/${subdir}" ]] \
    || fail "missing comfyui model directory: ${AGENTIC_ROOT:-/srv/agentic}/comfyui/models/${subdir}"
done
ok "flux bootstrap ensured comfyui model directories"

if "${agent_bin}" comfyui flux-1-dev --download --no-egress-check >/tmp/agent-i2-flux-download.out 2>&1; then
  fail "agent comfyui flux-1-dev --download should fail without HF token for gated Flux.1-dev files"
fi
if ! rg -q "missing HF token for gated repo" /tmp/agent-i2-flux-download.out; then
  fail "expected missing HF token error in download output"
fi
ok "flux download path executes and enforces HF token requirement for gated files"

ok "I2_comfyui_flux_bootstrap passed"
