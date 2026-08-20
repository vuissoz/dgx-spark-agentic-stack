# ComfyUI model bundles

Start ComfyUI, then install one or both public model bundles:

```bash
./agent start comfyui
./agent comfyui minimax-h3 --download
./agent comfyui flux2-dev --download
```

The commands are idempotent. They skip files whose pinned size and SHA-256 are
valid, retain interrupted transfers with a `.part` suffix for resumption, and
write bundle manifests under `/comfyui/models`.

Run either command without `--download` to check presence and expected sizes:

```bash
./agent comfyui minimax-h3
./agent comfyui flux2-dev
```

Use `--force` with `--download` only to replace a corrupt or deliberately
updated file. In `rootless-dev`, the persistent host tree defaults to
`~/.local/share/agentic/comfyui/models`; in `strict-prod`, it defaults to
`/srv/agentic/comfyui/models`. Both are mounted at `/comfyui/models` in the
container.

The controlled egress proxy must allow `huggingface.co` and the exact artifact
host `us.aws.cdn.hf.co`. `agent up` reconciles these canonical entries into an
existing runtime allowlist without removing operator entries.
