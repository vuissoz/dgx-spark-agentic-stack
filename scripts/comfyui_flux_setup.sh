#!/usr/bin/env bash
set -euo pipefail

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
AGENTIC_COMPOSE_PROJECT="${AGENTIC_COMPOSE_PROJECT:-agentic}"

download_models=0
dry_run=0
force_download=0
egress_check=1
hf_token_file=""

usage() {
  cat <<'USAGE'
Usage:
  comfyui_flux_setup.sh [--download] [--force] [--hf-token-file <path>] [--no-egress-check] [--dry-run]

Behavior:
  - Always bootstraps Flux.1-dev model layout + manifest under ${AGENTIC_ROOT}/comfyui/models.
  - Optionally downloads required files from Hugging Face when --download is set.
  - If --hf-token-file is not provided, uses ${AGENTIC_ROOT}/secrets/runtime/huggingface.token when present.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --download)
      download_models=1
      shift
      ;;
    --force)
      force_download=1
      shift
      ;;
    --hf-token-file)
      [[ $# -ge 2 ]] || die "--hf-token-file requires a path argument"
      hf_token_file="$2"
      shift 2
      ;;
    --no-egress-check)
      egress_check=0
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_cmd docker
require_cmd python3

comfy_cid="$(docker ps \
  --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
  --filter "label=com.docker.compose.service=comfyui" \
  --format '{{.ID}}' | head -n 1)"
[[ -n "${comfy_cid}" ]] || die "ComfyUI container is not running (service=comfyui, project=${AGENTIC_COMPOSE_PROJECT})"

models_root="${AGENTIC_ROOT}/comfyui/models"
manifest_file="${models_root}/flux1-dev.manifest.json"
mkdir -p "${models_root}/checkpoints" "${models_root}/clip" "${models_root}/vae"

cat >"${manifest_file}" <<'JSON'
{
  "model": "flux1-dev",
  "updated_by": "agent comfyui flux-1-dev",
  "files": [
    {
      "target": "checkpoints/flux1-dev.safetensors",
      "repo_id": "black-forest-labs/FLUX.1-dev",
      "filename": "flux1-dev.safetensors",
      "gated": true
    },
    {
      "target": "vae/ae.safetensors",
      "repo_id": "black-forest-labs/FLUX.1-dev",
      "filename": "ae.safetensors",
      "gated": true
    },
    {
      "target": "clip/clip_l.safetensors",
      "repo_id": "comfyanonymous/flux_text_encoders",
      "filename": "clip_l.safetensors",
      "gated": false
    },
    {
      "target": "clip/t5xxl_fp16.safetensors",
      "repo_id": "comfyanonymous/flux_text_encoders",
      "filename": "t5xxl_fp16.safetensors",
      "gated": false
    }
  ],
  "sources": [
    "https://huggingface.co/black-forest-labs/FLUX.1-dev",
    "https://huggingface.co/comfyanonymous/flux_text_encoders",
    "https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main/model-list.json",
    "https://api.comfy.org/nodes"
  ]
}
JSON

if [[ "${egress_check}" == "1" ]]; then
  if [[ "${dry_run}" == "1" ]]; then
    echo "dry-run: skipping egress probe from ComfyUI container"
  else
    docker exec -i "${comfy_cid}" python3 - <<'PY' || die "ComfyUI egress probe failed (verify proxy allowlist and DNS)"
import urllib.request

urls = [
    "https://huggingface.co",
    "https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main/model-list.json",
    "https://api.comfy.org/nodes",
]
for url in urls:
    with urllib.request.urlopen(url, timeout=15) as resp:
        if resp.status < 200 or resp.status >= 400:
            raise SystemExit(f"unexpected status {resp.status} for {url}")
print("comfyui egress probe: ok")
PY
  fi
fi

if [[ "${download_models}" == "1" ]]; then
  hf_token="${HF_TOKEN:-}"
  default_hf_token_file="${AGENTIC_ROOT}/secrets/runtime/huggingface.token"
  if [[ -z "${hf_token}" && -z "${hf_token_file}" && -f "${default_hf_token_file}" ]]; then
    hf_token_file="${default_hf_token_file}"
  fi
  if [[ -z "${hf_token}" && -n "${hf_token_file}" ]]; then
    [[ -f "${hf_token_file}" ]] || die "HF token file not found: ${hf_token_file}"
    hf_token="$(tr -d '\r\n' <"${hf_token_file}")"
  fi

  if [[ "${dry_run}" == "1" ]]; then
    echo "dry-run: model download requested, but skipped"
  else
    if [[ -z "${hf_token}" ]]; then
      warn "HF token not provided (HF_TOKEN or --hf-token-file)."
      warn "Gated Flux.1-dev files will likely fail without prior license acceptance + token."
    fi
    docker exec -i \
      -e HF_TOKEN="${hf_token}" \
      -e FLUX_FORCE_DOWNLOAD="${force_download}" \
      "${comfy_cid}" \
      python3 - <<'PY'
import os
from huggingface_hub import hf_hub_download

force = os.getenv("FLUX_FORCE_DOWNLOAD", "0") == "1"
token = os.getenv("HF_TOKEN") or None
base = "/comfyui/models"
specs = [
    ("black-forest-labs/FLUX.1-dev", "flux1-dev.safetensors", "checkpoints", True),
    ("black-forest-labs/FLUX.1-dev", "ae.safetensors", "vae", True),
    ("comfyanonymous/flux_text_encoders", "clip_l.safetensors", "clip", False),
    ("comfyanonymous/flux_text_encoders", "t5xxl_fp16.safetensors", "clip", False),
]
for repo_id, filename, subdir, gated in specs:
    local_dir = os.path.join(base, subdir)
    os.makedirs(local_dir, exist_ok=True)
    target_path = os.path.join(local_dir, filename)
    if os.path.exists(target_path) and not force:
        print(f"skip existing: {target_path}")
        continue
    if gated and not token:
        raise SystemExit(
            f"missing HF token for gated repo {repo_id}; set HF_TOKEN or use --hf-token-file"
        )
    print(f"download: {repo_id}/{filename} -> {target_path}")
    hf_hub_download(
        repo_id=repo_id,
        filename=filename,
        local_dir=local_dir,
        local_dir_use_symlinks=False,
        token=token,
        resume_download=True,
    )
PY
  fi
fi

python3 - "${manifest_file}" "${models_root}" <<'PY'
import json
import os
import sys

manifest_path, models_root = sys.argv[1], sys.argv[2]
payload = json.loads(open(manifest_path, "r", encoding="utf-8").read())
files = payload.get("files", [])
missing = []
present = []
for item in files:
    target = item["target"]
    absolute_path = os.path.join(models_root, target)
    if os.path.exists(absolute_path):
        present.append(target)
    else:
        missing.append(target)

print(f"flux manifest: {manifest_path}")
print(f"present_files={len(present)} missing_files={len(missing)}")
for target in present:
    print(f"  OK  {target}")
for target in missing:
    print(f"  MISS {target}")
PY

if [[ "${download_models}" != "1" ]]; then
  cat <<'EOF'
Next step:
  agent comfyui flux-1-dev --download --hf-token-file /path/to/hf_token
EOF
fi
