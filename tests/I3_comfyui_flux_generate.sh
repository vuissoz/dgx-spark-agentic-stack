#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_I_TESTS:-0}" == "1" ]]; then
  ok "I3 skipped because AGENTIC_SKIP_I_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd python3

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

comfy_cid="$(require_service_container comfyui)" || exit 1
wait_for_container_ready "${comfy_cid}" 300 || fail "comfyui is not ready"
comfy_backend_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${comfy_cid}")"
[[ -n "${comfy_backend_ip}" ]] || fail "unable to resolve comfyui backend IP"

mem_limit_bytes="$(docker inspect --format '{{.HostConfig.Memory}}' "${comfy_cid}")"
python3 - "${mem_limit_bytes}" <<'PY' || fail "comfyui memory limit is too low for Flux.1-dev generation"
import sys

mem_limit = int(sys.argv[1])
minimum = 64 * 1024 * 1024 * 1024
if mem_limit < minimum:
    raise SystemExit(
        f"ComfyUI memory limit is {mem_limit} bytes; need at least {minimum} bytes (64g) for Flux.1-dev smoke"
    )
PY
ok "comfyui memory limit is large enough for Flux.1-dev smoke"

"${agent_bin}" comfyui flux-1-dev --no-egress-check >/tmp/agent-i3-flux-bootstrap.out \
  || fail "agent comfyui flux-1-dev bootstrap command failed"

manifest_path="${AGENTIC_ROOT:-/srv/agentic}/comfyui/models/flux1-dev.manifest.json"
[[ -s "${manifest_path}" ]] || fail "flux manifest is missing: ${manifest_path}"

models_root="${AGENTIC_ROOT:-/srv/agentic}/comfyui/models"
mapfile -t missing_targets < <(
  python3 - "${manifest_path}" "${models_root}" <<'PY'
import json
import os
import sys

manifest_path = sys.argv[1]
models_root = sys.argv[2]
payload = json.loads(open(manifest_path, "r", encoding="utf-8").read())
for item in payload.get("files", []):
    target = item.get("target")
    if not target:
        continue
    if not os.path.exists(os.path.join(models_root, target)):
        print(target)
PY
)

if [[ "${#missing_targets[@]}" -gt 0 ]]; then
  hf_token_file="${AGENTIC_ROOT:-/srv/agentic}/secrets/runtime/huggingface.token"
  download_args=(comfyui flux-1-dev --download --no-egress-check)
  if [[ -s "${hf_token_file}" ]]; then
    download_args+=(--hf-token-file "${hf_token_file}")
  fi

  "${agent_bin}" "${download_args[@]}" >/tmp/agent-i3-flux-download.out 2>&1 \
    || fail "Flux.1-dev download/ensure failed while required files were missing: ${missing_targets[*]}"

  mapfile -t missing_targets < <(
    python3 - "${manifest_path}" "${models_root}" <<'PY'
import json
import os
import sys

manifest_path = sys.argv[1]
models_root = sys.argv[2]
payload = json.loads(open(manifest_path, "r", encoding="utf-8").read())
for item in payload.get("files", []):
    target = item.get("target")
    if not target:
        continue
    if not os.path.exists(os.path.join(models_root, target)):
        print(target)
PY
  )
fi

[[ "${#missing_targets[@]}" -eq 0 ]] || fail "required Flux.1-dev files are still missing after bootstrap/download: ${missing_targets[*]}"
ok "Flux.1-dev runtime files are present"

wait_for_container_ready "${comfy_cid}" 300 || fail "comfyui is not ready before Flux.1-dev workflow execution"

prompt_text="Beautiful photography of a gorgeous-haired female artist, natural and authentic, her hair styled in a messy casual bun, smiling joyfully and looking directly at the camera, cinematic lighting, soft natural daylight, shallow depth of field, warm gentle tones, film grain, high detail, 8K, realistic portrait "
prefix="i3-flux-smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$"
output_root="${AGENTIC_ROOT:-/srv/agentic}/comfyui/output"
restart_count_before="$(docker inspect --format '{{.RestartCount}}' "${comfy_cid}")"

set +e
python3 - "${comfy_backend_ip}" "${comfy_cid}" "${restart_count_before}" "${output_root}" "${prefix}" "${prompt_text}" <<'PY'
import json
import os
import pathlib
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request

backend_ip = sys.argv[1]
container_id = sys.argv[2]
restart_count_before = int(sys.argv[3])
output_root = pathlib.Path(sys.argv[4])
prefix = sys.argv[5]
prompt_text = sys.argv[6]
base = f"http://{backend_ip}:8188"

prompt = {
    "1": {
        "class_type": "UNETLoader",
        "inputs": {
            "unet_name": "flux1-dev.safetensors",
            "weight_dtype": "default",
        },
    },
    "2": {
        "class_type": "DualCLIPLoader",
        "inputs": {
            "clip_name1": "clip_l.safetensors",
            "clip_name2": "t5xxl_fp16.safetensors",
            "type": "flux",
        },
    },
    "3": {
        "class_type": "VAELoader",
        "inputs": {"vae_name": "ae.safetensors"},
    },
    "4": {
        "class_type": "CLIPTextEncodeFlux",
        "inputs": {
            "clip": ["2", 0],
            "clip_l": prompt_text,
            "t5xxl": prompt_text,
            "guidance": 3.5,
        },
    },
    "5": {
        "class_type": "EmptySD3LatentImage",
        "inputs": {"width": 512, "height": 768, "batch_size": 1},
    },
    "6": {
        "class_type": "ModelSamplingFlux",
        "inputs": {
            "model": ["1", 0],
            "max_shift": 1.15,
            "base_shift": 0.5,
            "width": 512,
            "height": 768,
        },
    },
    "7": {
        "class_type": "BasicGuider",
        "inputs": {
            "model": ["6", 0],
            "conditioning": ["4", 0],
        },
    },
    "8": {
        "class_type": "RandomNoise",
        "inputs": {"noise_seed": 424242},
    },
    "9": {
        "class_type": "KSamplerSelect",
        "inputs": {"sampler_name": "euler"},
    },
    "10": {
        "class_type": "BasicScheduler",
        "inputs": {
            "model": ["6", 0],
            "scheduler": "simple",
            "steps": 4,
            "denoise": 1.0,
        },
    },
    "11": {
        "class_type": "SamplerCustomAdvanced",
        "inputs": {
            "noise": ["8", 0],
            "guider": ["7", 0],
            "sampler": ["9", 0],
            "sigmas": ["10", 0],
            "latent_image": ["5", 0],
        },
    },
    "12": {
        "class_type": "VAEDecode",
        "inputs": {
            "samples": ["11", 0],
            "vae": ["3", 0],
        },
    },
    "13": {
        "class_type": "SaveImage",
        "inputs": {
            "images": ["12", 0],
            "filename_prefix": prefix,
        },
    },
}

req = urllib.request.Request(
    f"{base}/prompt",
    data=json.dumps({"prompt": prompt}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=30) as resp:
    payload = json.loads(resp.read().decode("utf-8"))
prompt_id = payload.get("prompt_id")
if not prompt_id:
    raise SystemExit("missing prompt_id in ComfyUI response")

deadline = time.time() + 900
last_error = None
while time.time() < deadline:
    restart_count = int(
        subprocess.check_output(
            ["docker", "inspect", "--format", "{{.RestartCount}}", container_id],
            text=True,
        ).strip()
    )
    if restart_count > restart_count_before:
        raise SystemExit(
            f"ComfyUI container restarted during Flux.1-dev workflow execution "
            f"(restart_count {restart_count_before} -> {restart_count})"
        )

    try:
        with urllib.request.urlopen(f"{base}/history/{prompt_id}", timeout=20) as resp:
            history_payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        last_error = f"history HTTP error: {exc.code}"
        time.sleep(5)
        continue
    except OSError as exc:
        last_error = f"history transport error: {exc}"
        time.sleep(5)
        continue

    details = history_payload.get(prompt_id) or {}
    status = details.get("status") or {}
    if status.get("status_str") in {"error", "failed"}:
        raise SystemExit(json.dumps(details, indent=2))

    outputs = details.get("outputs") or {}
    images = (outputs.get("13") or {}).get("images") or []
    if images:
        image = images[0]
        filename = image.get("filename")
        if not filename:
            raise SystemExit(f"SaveImage output is missing filename metadata: {image!r}")
        subfolder = image.get("subfolder") or ""
        output_path = output_root / subfolder / filename
        if not output_path.is_file():
            raise SystemExit(f"expected output file not found: {output_path}")
        if output_path.stat().st_size <= 0:
            raise SystemExit(f"output file is empty: {output_path}")
        with output_path.open("rb") as fh:
            header = fh.read(24)
        if header[:8] != b"\x89PNG\r\n\x1a\n":
            raise SystemExit(f"output file is not a PNG: {output_path}")
        width, height = struct.unpack(">II", header[16:24])
        if width <= 0 or height <= 0:
            raise SystemExit(f"invalid PNG dimensions for {output_path}: {width}x{height}")
        print(f"OK: flux output {output_path} ({width}x{height})")
        raise SystemExit(0)

    time.sleep(5)

message = "Flux.1-dev workflow did not complete before timeout"
if last_error:
    message = f"{message}; last_error={last_error}"
raise SystemExit(message)
PY
workflow_rc=$?
set -e

[[ "${workflow_rc}" -eq 0 ]] || fail "Flux.1-dev workflow execution failed"
ok "Flux.1-dev workflow executed successfully and produced a PNG output"

ok "I3_comfyui_flux_generate passed"
