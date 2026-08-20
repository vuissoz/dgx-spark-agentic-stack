#!/usr/bin/env bash
set -euo pipefail

AGENTIC_COMPOSE_PROJECT="${AGENTIC_COMPOSE_PROJECT:-agentic}"

bundle="${1:-}"
[[ -n "${bundle}" ]] || { echo "ERROR: missing model bundle" >&2; exit 1; }
shift

download_models=0
force_download=0
dry_run=0

usage() {
  cat <<'USAGE'
Usage:
  comfyui_model_bundle.sh <minimax-h3|flux2-dev> [--download] [--force] [--dry-run]

The command writes a manifest under /comfyui/models and downloads public Hugging
Face files directly from the ComfyUI container into its persistent model tree.
Existing files are skipped only after their pinned size and SHA-256 are verified.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --download) download_models=1 ;;
    --force) force_download=1 ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

case "${bundle}" in
  minimax-h3|minimax_h3) bundle="minimax-h3" ;;
  flux2-dev|flux2_dev|flux-2-dev) bundle="flux2-dev" ;;
  *) usage >&2; die "unknown model bundle: ${bundle}" ;;
esac

command -v docker >/dev/null 2>&1 || die "required command not found: docker"

comfy_cid="$(docker ps \
  --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
  --filter "label=com.docker.compose.service=comfyui" \
  --format '{{.ID}}' | head -n 1)"
[[ -n "${comfy_cid}" ]] || die "ComfyUI is not running; start it with: agent start comfyui"

if [[ "${dry_run}" == "1" ]]; then
  echo "dry-run: bundle=${bundle} download=${download_models} force=${force_download}"
  exit 0
fi

docker exec -i \
  -e COMFYUI_MODEL_BUNDLE="${bundle}" \
  -e COMFYUI_DOWNLOAD_MODELS="${download_models}" \
  -e COMFYUI_FORCE_DOWNLOAD="${force_download}" \
  "${comfy_cid}" python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import shutil
import urllib.request

bundle = os.environ["COMFYUI_MODEL_BUNDLE"]
download = os.environ.get("COMFYUI_DOWNLOAD_MODELS") == "1"
force = os.environ.get("COMFYUI_FORCE_DOWNLOAD") == "1"
models_root = pathlib.Path("/comfyui/models")

bundles = {
    "minimax-h3": [
        ("vae/minimax_h3_audio_vae_fp32.safetensors", "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors", 605254808, "8e505d95dd1561d47abd43d4238fd40d9bb1ae9e147ed0a4cba778d76ae4db48"),
        ("vae/minimax_h3_video_vae_fp16.safetensors", "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors", 5207808496, "7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522"),
        ("text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors", "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors", 15687142551, "35a88d51044231fe332301d7a62aa81e3f2cba62febeb446e2c1e3e0ef76f2c6"),
        ("diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors", "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors", 20970379616, "e889202c41dafb67b10d67b97f0d8541508036a6090af23425a5c2615d03c47a"),
    ],
    "flux2-dev": [
        ("loras/Flux2TurboComfyv2.safetensors", "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/loras/Flux2TurboComfyv2.safetensors", 2760814872, "dfc97af0180d432269361a7bc36b4a7df6a2a3ffb630763f8c3343d3d1991d87"),
        ("vae/flux2-vae.safetensors", "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors", 336213556, "d64f3a68e1cc4f9f4e29b6e0da38a0204fe9a49f2d4053f0ec1fa1ca02f9c4b5"),
        ("text_encoders/mistral_3_small_flux2_fp8.safetensors", "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/text_encoders/mistral_3_small_flux2_fp8.safetensors", 18034640095, "e3467b7d912a234fb929cdf215dc08efdb011810b44bc21081c4234cc75b370e"),
    ],
}

files = bundles[bundle]
manifest_path = models_root / f"{bundle}.manifest.json"
manifest_path.parent.mkdir(parents=True, exist_ok=True)
manifest = {
    "schema_version": 1,
    "model": bundle,
    "updated_by": f"agent comfyui {bundle}",
    "files": [
        {"target": target, "url": url, "expected_size": size, "sha256": sha256}
        for target, url, size, sha256 in files
    ],
}
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(f"manifest: {manifest_path}", flush=True)

def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def download_file(url: str, target: pathlib.Path, expected_size: int, expected_sha256: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file() and target.stat().st_size == expected_size and not force:
        actual_sha256 = sha256_file(target)
        if actual_sha256 == expected_sha256:
            print(f"skip verified: {target} ({expected_size} bytes, sha256={actual_sha256})", flush=True)
            return
        raise SystemExit(
            f"existing file checksum mismatch: {target} "
            f"({actual_sha256} != {expected_sha256}); rerun with --force"
        )
    if target.exists() and not force:
        raise SystemExit(
            f"existing file has unexpected size: {target} "
            f"({target.stat().st_size} != {expected_size}); rerun with --force"
        )

    partial = target.with_name(target.name + ".part")
    resume_at = partial.stat().st_size if partial.exists() and not force else 0
    if force and partial.exists():
        partial.unlink()
        resume_at = 0

    headers = {"User-Agent": "dgx-spark-agentic-stack/1"}
    if resume_at:
        headers["Range"] = f"bytes={resume_at}-"
    request = urllib.request.Request(url, headers=headers)
    print(f"download: {url} -> {target} (resume={resume_at})", flush=True)
    with urllib.request.urlopen(request, timeout=120) as response:
        append = resume_at > 0 and response.status == 206
        if resume_at > 0 and not append:
            resume_at = 0
        with partial.open("ab" if append else "wb") as output:
            shutil.copyfileobj(response, output, length=8 * 1024 * 1024)
    actual_size = partial.stat().st_size
    if actual_size != expected_size:
        raise SystemExit(
            f"download size mismatch for {target}: {actual_size} != {expected_size}; "
            f"partial retained at {partial}"
        )
    actual_sha256 = sha256_file(partial)
    if actual_sha256 != expected_sha256:
        raise SystemExit(
            f"download checksum mismatch for {target}: {actual_sha256} != {expected_sha256}; "
            f"partial retained at {partial}"
        )
    partial.replace(target)
    print(f"complete: {target} ({actual_size} bytes, sha256={actual_sha256})", flush=True)

if download:
    for relative_target, url, expected_size, expected_sha256 in files:
        download_file(url, models_root / relative_target, expected_size, expected_sha256)

missing = []
invalid = []
for relative_target, _, expected_size, _ in files:
    target = models_root / relative_target
    if not target.is_file():
        missing.append(relative_target)
    elif target.stat().st_size != expected_size:
        invalid.append((relative_target, target.stat().st_size, expected_size))

print(f"bundle={bundle} present={len(files) - len(missing) - len(invalid)} missing={len(missing)} invalid={len(invalid)}")
for target in missing:
    print(f"  MISS {target}")
for target, actual, expected in invalid:
    print(f"  BAD  {target} size={actual} expected={expected}")
if download and (missing or invalid):
    raise SystemExit(1)
PY
