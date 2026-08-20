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

# Keep the negative download path deterministic. The setup helper otherwise
# discovers a host-managed Hugging Face token and can start a real, long-running
# gated download during a regression test. An explicit empty file disables that
# fallback while still exercising the same CLI contract.
empty_hf_token_file="$(mktemp)"
trap 'rm -f "${empty_hf_token_file}"' EXIT

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
if not isinstance(files, list) or len(files) < 5:
    raise SystemExit("manifest files array is missing or too small")
required_targets = {
    "diffusion_models/flux1-dev.safetensors",
    "diffusion_models/flux1-fill-dev.safetensors",
    "vae/ae.safetensors",
    "text_encoders/clip_l.safetensors",
    "text_encoders/t5xxl_fp16.safetensors",
}
seen_targets = {item.get("target") for item in files if isinstance(item, dict)}
missing = sorted(required_targets - seen_targets)
if missing:
    raise SystemExit(f"manifest missing required targets: {missing}")
fill = next(item for item in files if item.get("target") == "diffusion_models/flux1-fill-dev.safetensors")
if fill.get("expected_size") != 23804922408:
    raise SystemExit("Flux.1 Fill expected size is not pinned")
if fill.get("sha256") != "03e289f530df51d014f48e675a9ffa2141bc003259bf5f25d75b957e920a41ca":
    raise SystemExit("Flux.1 Fill SHA-256 is not pinned")
PY
ok "flux manifest contains required Flux.1-dev runtime targets"

for subdir in diffusion_models text_encoders vae checkpoints clip; do
  [[ -d "${AGENTIC_ROOT:-/srv/agentic}/comfyui/models/${subdir}" ]] \
    || fail "missing comfyui model directory: ${AGENTIC_ROOT:-/srv/agentic}/comfyui/models/${subdir}"
done
ok "flux bootstrap ensured comfyui model directories and legacy compatibility locations"

missing_gated_count="$(python3 - "${manifest_path}" "${AGENTIC_ROOT:-/srv/agentic}/comfyui/models" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
models_root = pathlib.Path(sys.argv[2])
print(sum(1 for item in manifest["files"] if item.get("gated") and not (models_root / item["target"]).exists()))
PY
)"
if (( missing_gated_count > 0 )); then
  set +e
  env -u HF_TOKEN "${agent_bin}" comfyui flux-1-dev --download \
    --hf-token-file "${empty_hf_token_file}" --no-egress-check >/tmp/agent-i2-flux-download.out 2>&1
  download_rc=$?
  set -e
  [[ "${download_rc}" -ne 0 ]] || fail "tokenless download unexpectedly succeeded with missing gated files"
  if ! rg -q "missing HF token for gated repo" /tmp/agent-i2-flux-download.out; then
    fail "expected missing HF token error in download output when download path fails"
  fi
  ok "flux download path enforces HF token requirement when gated files are missing"
else
  ok "flux long-running download path skipped because gated runtime files are already present"
fi

ok "I2_comfyui_flux_bootstrap passed"
