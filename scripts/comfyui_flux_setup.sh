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
mkdir -p \
  "${models_root}/diffusion_models" \
  "${models_root}/text_encoders" \
  "${models_root}/vae" \
  "${models_root}/checkpoints" \
  "${models_root}/clip"

cat >"${manifest_file}" <<'JSON'
{
  "model": "flux1-dev",
  "updated_by": "agent comfyui flux-1-dev",
  "files": [
    {
      "target": "diffusion_models/flux1-dev.safetensors",
      "relative_path": "models/diffusion_models",
      "repo_id": "black-forest-labs/FLUX.1-dev",
      "filename": "flux1-dev.safetensors",
      "url": "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors",
      "legacy_targets": [
        "checkpoints/flux1-dev.safetensors"
      ],
      "gated": true
    },
    {
      "target": "vae/ae.safetensors",
      "relative_path": "models/vae",
      "repo_id": "black-forest-labs/FLUX.1-dev",
      "filename": "ae.safetensors",
      "url": "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors",
      "gated": true
    },
    {
      "target": "text_encoders/clip_l.safetensors",
      "relative_path": "models/text_encoders",
      "repo_id": "comfyanonymous/flux_text_encoders",
      "filename": "clip_l.safetensors",
      "url": "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors",
      "legacy_targets": [
        "clip/clip_l.safetensors"
      ],
      "gated": false
    },
    {
      "target": "text_encoders/t5xxl_fp16.safetensors",
      "relative_path": "models/text_encoders",
      "repo_id": "comfyanonymous/flux_text_encoders",
      "filename": "t5xxl_fp16.safetensors",
      "url": "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors",
      "legacy_targets": [
        "clip/t5xxl_fp16.safetensors"
      ],
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

python3 - "${manifest_file}" "${models_root}" <<'PY'
import json
import os
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
models_root = pathlib.Path(sys.argv[2])
payload = json.loads(manifest_path.read_text(encoding="utf-8"))

for item in payload.get("files", []):
    if not isinstance(item, dict):
        continue
    target = item.get("target")
    if not target:
        continue
    target_path = models_root / target
    target_path.parent.mkdir(parents=True, exist_ok=True)
    legacy_targets = item.get("legacy_targets") or []
    for legacy_target in legacy_targets:
        legacy_path = models_root / legacy_target
        legacy_path.parent.mkdir(parents=True, exist_ok=True)
        if target_path.exists() and not legacy_path.exists():
            legacy_path.symlink_to(os.path.relpath(target_path, legacy_path.parent))
        elif legacy_path.exists() and not target_path.exists():
            target_path.symlink_to(os.path.relpath(legacy_path, target_path.parent))
PY

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
      -e FLUX_MANIFEST_FILE="/comfyui/models/flux1-dev.manifest.json" \
      "${comfy_cid}" \
      python3 - <<'PY'
import json
import os
import pathlib
import subprocess
import sys

force = os.getenv("FLUX_FORCE_DOWNLOAD", "0") == "1"
token = os.getenv("HF_TOKEN") or None
manifest_file = pathlib.Path(os.getenv("FLUX_MANIFEST_FILE", "/comfyui/models/flux1-dev.manifest.json"))
models_root = manifest_file.parent
payload = json.loads(manifest_file.read_text(encoding="utf-8"))

for item in payload.get("files", []):
    if not isinstance(item, dict):
        continue
    target = item.get("target")
    url = item.get("url")
    relative_path = item.get("relative_path")
    filename = item.get("filename")
    repo_id = item.get("repo_id")
    gated = bool(item.get("gated"))
    if not target or not url or not relative_path or not filename:
        raise SystemExit(f"invalid manifest entry: {item!r}")

    target_path = models_root / target
    target_path.parent.mkdir(parents=True, exist_ok=True)
    if target_path.exists() and not force:
        print(f"skip existing: {target_path}")
        continue
    if gated and not token:
        raise SystemExit(
            f"missing HF token for gated repo {repo_id}; set HF_TOKEN or use --hf-token-file"
        )

    cmd = [
        "comfy",
        "--workspace",
        "/opt/comfyui",
        "model",
        "download",
        "--url",
        url,
        "--relative-path",
        relative_path,
        "--filename",
        filename,
    ]
    if token:
        cmd.extend(["--set-hf-api-token", token])

    print(f"download: {url} -> {target_path}")
    subprocess.run(cmd, check=True)
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
    for legacy_target in item.get("legacy_targets", []):
        legacy_absolute_path = os.path.join(models_root, legacy_target)
        if os.path.exists(legacy_absolute_path) and legacy_target not in present:
            present.append(legacy_target)

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
