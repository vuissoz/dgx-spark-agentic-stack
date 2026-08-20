# ComfyUI model bundles

Start ComfyUI, then install any of the public model bundles you need:

```bash
./agent start comfyui
./agent comfyui minimax-h3 --download
./agent comfyui flux2-dev --download
./agent comfyui stable-audio-3 --download
./agent comfyui ace-step-v1 --download
./agent comfyui ace-step-1.5 --download
```

The commands are idempotent. They skip files whose pinned size and SHA-256 are
valid, retain interrupted transfers with a `.part` suffix for resumption, and
write bundle manifests under `/comfyui/models`. A per-bundle lock refuses a
second concurrent installer so two processes cannot modify the same `.part`.

Run either command without `--download` to check presence and expected sizes:

```bash
./agent comfyui minimax-h3
./agent comfyui flux2-dev
./agent comfyui stable-audio-3
./agent comfyui ace-step-v1
./agent comfyui ace-step-1.5
```

For an explicit rootless development deployment, use the profile prefix. The
same persistent model tree is reused across container recreation:

```bash
./agent rootless-dev start comfyui
./agent rootless-dev comfyui minimax-h3 --download
./agent rootless-dev comfyui stable-audio-3 --download
./agent rootless-dev comfyui ace-step-v1 --download
./agent rootless-dev comfyui ace-step-1.5 --download
```

The `minimax-h3` bundle installs both requested INT8 diffusion variants:
`minimax_h3_fl2va_pruned_int8_convrot.safetensors` and
`minimax_h3_ref2va_pruned_int8_convrot.safetensors`. Together with its VAEs and
text encoder, the complete bundle requires approximately 63.4 GB.

The `flux-1-dev` bootstrap also installs
`diffusion_models/flux1-fill-dev.safetensors` for Flux Fill workflows. This
public artifact adds approximately 23.8 GB and is verified against its pinned
size and SHA-256. The base Flux.1-dev weights remain gated and still require
license acceptance plus a Hugging Face token when they are not already present.

The audio bundles install the files at the paths expected by ComfyUI:

| Bundle | Installed content | Approximate download |
| --- | --- | ---: |
| `stable-audio-3` | medium checkpoint, Qwen 3.5 2B and T5Gemma text encoders | 15.0 GB |
| `ace-step-v1` | ACE-Step v1 3.5B all-in-one checkpoint | 7.7 GB |
| `ace-step-1.5` | VAE, Qwen 0.6B and 4B encoders, XL SFT diffusion model, turbo all-in-one checkpoint | 29.9 GB |

`ace-step-1.5` intentionally includes both the split XL SFT workflow files and
the turbo all-in-one checkpoint requested for the AIO workflow. They duplicate
some model data, so ensure roughly 30 GB of free disk space before downloading.
The duplicated ACE-Step v1 source URL is represented by one manifest entry and
is therefore downloaded only once.

Use `--force` with `--download` only to replace a corrupt or deliberately
updated file. In `rootless-dev`, the persistent host tree defaults to
`~/.local/share/agentic/comfyui/models`; in `strict-prod`, it defaults to
`/srv/agentic/comfyui/models`. Both are mounted at `/comfyui/models` in the
container.

The controlled egress proxy must allow `huggingface.co` and the exact artifact
host `us.aws.cdn.hf.co`. `agent up` reconciles these canonical entries into an
existing runtime allowlist without removing operator entries.
