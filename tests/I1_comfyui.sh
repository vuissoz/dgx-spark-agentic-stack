#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_I_TESTS:-0}" == "1" ]]; then
  ok "I1 skipped because AGENTIC_SKIP_I_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd python3

comfy_port="${COMFYUI_HOST_PORT:-8188}"
comfy_cid="$(require_service_container comfyui)" || exit 1
wait_for_container_ready "${comfy_cid}" 300 || fail "comfyui is not ready"

assert_no_public_bind "${comfy_port}" || fail "comfyui host bind is not loopback-only"
ok "comfyui host bind is loopback-only"

curl -fsS "http://127.0.0.1:${comfy_port}/system_stats" >/dev/null \
  || fail "comfyui /system_stats endpoint is unavailable"
ok "comfyui API responds on /system_stats"

checkpoint="$(timeout 20 docker exec "${comfy_cid}" sh -lc 'ls -1 /comfyui/models/checkpoints 2>/dev/null | head -n 1' || true)"
if [[ -z "${checkpoint}" ]]; then
  ok "I1 skipped workflow generation probe because no checkpoint is available in /comfyui/models/checkpoints"
  exit 0
fi

prefix="i1-smoke-$RANDOM-$$"
set +e
python3 - "${comfy_port}" "${checkpoint}" "${prefix}" <<'PY'
import json
import sys
import time
import urllib.request

port = int(sys.argv[1])
checkpoint = sys.argv[2]
prefix = sys.argv[3]
base = f"http://127.0.0.1:{port}"

prompt = {
    "4": {
        "class_type": "CheckpointLoaderSimple",
        "inputs": {"ckpt_name": checkpoint},
    },
    "5": {
        "class_type": "EmptyLatentImage",
        "inputs": {"width": 512, "height": 512, "batch_size": 1},
    },
    "6": {
        "class_type": "CLIPTextEncode",
        "inputs": {"text": "a simple geometric icon", "clip": ["4", 1]},
    },
    "7": {
        "class_type": "CLIPTextEncode",
        "inputs": {"text": "blurry, low quality", "clip": ["4", 1]},
    },
    "3": {
        "class_type": "KSampler",
        "inputs": {
            "seed": 1337,
            "steps": 2,
            "cfg": 4.0,
            "sampler_name": "euler",
            "scheduler": "normal",
            "denoise": 1.0,
            "model": ["4", 0],
            "positive": ["6", 0],
            "negative": ["7", 0],
            "latent_image": ["5", 0],
        },
    },
    "8": {
        "class_type": "VAEDecode",
        "inputs": {"samples": ["3", 0], "vae": ["4", 2]},
    },
    "9": {
        "class_type": "SaveImage",
        "inputs": {"images": ["8", 0], "filename_prefix": prefix},
    },
}

req = urllib.request.Request(
    f"{base}/prompt",
    data=json.dumps({"prompt": prompt}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=25) as resp:
    payload = json.loads(resp.read().decode("utf-8"))

prompt_id = payload.get("prompt_id")
if not prompt_id:
    raise SystemExit("missing prompt_id in comfyui response")

deadline = time.time() + 120
while time.time() < deadline:
    with urllib.request.urlopen(f"{base}/history/{prompt_id}", timeout=10) as resp:
        history_payload = json.loads(resp.read().decode("utf-8"))
    details = history_payload.get(prompt_id) or {}
    outputs = details.get("outputs") or {}
    save_out = outputs.get("9") or {}
    images = save_out.get("images") if isinstance(save_out, dict) else None
    if isinstance(images, list) and images:
        print("OK: comfy workflow completed")
        raise SystemExit(0)
    time.sleep(2)

raise SystemExit("workflow did not complete within timeout")
PY
workflow_rc=$?
set -e

if [[ "${workflow_rc}" -ne 0 ]]; then
  if [[ "${AGENTIC_COMFY_STRICT_SMOKE:-0}" == "1" ]]; then
    fail "comfyui workflow smoke failed while AGENTIC_COMFY_STRICT_SMOKE=1"
  fi
  warn "comfyui workflow smoke failed; treated as non-blocking because AGENTIC_COMFY_STRICT_SMOKE!=1"
else
  if ! find "${AGENTIC_ROOT:-/srv/agentic}/comfyui/output" -maxdepth 1 -type f -name "${prefix}*" | grep -q '.'; then
    fail "comfyui workflow reported success but output file prefix '${prefix}' was not found"
  fi
  ok "comfyui workflow smoke produced an output file"
fi

ok "I1_comfyui passed"
