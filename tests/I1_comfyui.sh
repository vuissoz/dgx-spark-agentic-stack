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

timeout 20 docker exec "${comfy_cid}" sh -lc 'test -d /opt/comfyui/custom_nodes/ComfyUI-Manager' \
  || fail "comfyui manager extension is missing (/opt/comfyui/custom_nodes/ComfyUI-Manager)"
ok "comfyui manager extension is installed"

timeout 20 docker exec "${comfy_cid}" sh -lc 'cd /opt/comfyui && git rev-parse --is-inside-work-tree >/dev/null' \
  || fail "comfyui source tree is not detected as a git repository under /opt/comfyui"
ok "comfyui source tree is a git repository"

mounts_json="$(docker inspect --format '{{json .Mounts}}' "${comfy_cid}" 2>/dev/null || true)"
python3 - "${mounts_json}" "${AGENTIC_ROOT:-/srv/agentic}/comfyui/custom_nodes" <<'PY'
import json
import sys

raw = sys.argv[1]
expected_source = sys.argv[2]
try:
    mounts = json.loads(raw)
except json.JSONDecodeError:
    raise SystemExit("comfyui has invalid Mounts payload")

if not isinstance(mounts, list):
    raise SystemExit("comfyui mounts payload is not a list")

for mount in mounts:
    if not isinstance(mount, dict):
        continue
    if mount.get("Destination") == "/opt/comfyui/custom_nodes" and mount.get("Source") == expected_source:
        raise SystemExit(0)

raise SystemExit(
    "comfyui custom_nodes mount is missing or points to an unexpected destination; "
    "expected host /srv path mapped to /opt/comfyui/custom_nodes"
)
PY
ok "comfyui custom_nodes persistence is mounted on /opt/comfyui/custom_nodes"

gpu_requests_json="$(docker inspect --format '{{json .HostConfig.DeviceRequests}}' "${comfy_cid}" 2>/dev/null || true)"
python3 - "${gpu_requests_json}" <<'PY'
import json
import sys

raw = sys.argv[1]
try:
    requests = json.loads(raw)
except json.JSONDecodeError:
    raise SystemExit("comfyui has invalid HostConfig.DeviceRequests payload")

if not isinstance(requests, list) or not requests:
    raise SystemExit("comfyui does not request GPU devices")

has_gpu_capability = False
for req in requests:
    if not isinstance(req, dict):
        continue
    for group in req.get("Capabilities") or []:
        if isinstance(group, list) and any(str(item).lower() == "gpu" for item in group):
            has_gpu_capability = True
            break
    if has_gpu_capability:
        break

if not has_gpu_capability:
    raise SystemExit("comfyui device requests do not include GPU capability")
PY
ok "comfyui is configured with a GPU device request"

docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${comfy_cid}" \
  | grep -q '^AGENTIC_GPU_PROFILE=lowprio$' \
  || fail "comfyui is missing AGENTIC_GPU_PROFILE=lowprio"
ok "comfyui low-priority GPU profile marker is present"

assert_proxy_enforced "${comfy_cid}" || fail "comfyui proxy environment baseline is not enforced"

set +e
timeout 20 docker exec "${comfy_cid}" sh -lc \
  'env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY python3 -c "import urllib.request; urllib.request.urlopen(\"https://example.com\", timeout=8).read(8)"'
direct_rc=$?
set -e
if [[ "${direct_rc}" -eq 0 ]]; then
  fail "comfyui direct egress succeeded without proxy"
fi
ok "comfyui direct egress is blocked when proxy env is removed"

proxy_access_log="${AGENTIC_ROOT:-/srv/agentic}/proxy/logs/access.log"
proxy_lines_before=0
if [[ -f "${proxy_access_log}" ]]; then
  proxy_lines_before="$(wc -l <"${proxy_access_log}" | tr -d ' ')"
fi

timeout 20 docker exec "${comfy_cid}" sh -lc '
python3 - <<'"'"'PY'"'"'
import urllib.error
import urllib.request

opener = urllib.request.build_opener(
    urllib.request.ProxyHandler(
        {
            "http": "http://egress-proxy:3128",
            "https": "http://egress-proxy:3128",
        }
    )
)

try:
    with opener.open("https://example.com", timeout=10) as resp:
        if resp.status < 200 or resp.status >= 500:
            raise SystemExit(f"unexpected proxy status {resp.status}")
except urllib.error.HTTPError as exc:
    if exc.code not in (403, 407):
        raise SystemExit(f"unexpected proxy HTTP error {exc.code}")
PY' || fail "comfyui could not reach egress-proxy with explicit proxy settings"

if [[ -f "${proxy_access_log}" ]]; then
  proxy_lines_after="$(wc -l <"${proxy_access_log}" | tr -d ' ')"
  if (( proxy_lines_after <= proxy_lines_before )); then
    fail "comfyui proxy request did not produce an egress-proxy access log entry"
  fi
  ok "comfyui proxy path is active (egress-proxy access log increased)"
else
  warn "proxy access log not found at ${proxy_access_log}; skipped log delta assertion"
fi

assert_no_public_bind "${comfy_port}" || fail "comfyui host bind is not loopback-only"
ok "comfyui host bind is loopback-only"

python3 - "${comfy_port}" <<'PY' || fail "comfyui websocket endpoint /ws is not upgrade-compatible via loopback proxy"
import base64
import os
import socket
import sys

port = int(sys.argv[1])
key = base64.b64encode(os.urandom(16)).decode("ascii")
request = (
    f"GET /ws HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{port}\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\n"
    "Sec-WebSocket-Version: 13\r\n"
    "\r\n"
)

with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
    sock.sendall(request.encode("ascii"))
    response = sock.recv(4096).decode("latin-1", errors="replace")

status_line = response.splitlines()[0] if response.splitlines() else ""
if " 101 " not in status_line:
    raise SystemExit(f"unexpected websocket handshake status: {status_line!r}")
PY
ok "comfyui websocket endpoint /ws upgrades correctly via loopback proxy"

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
