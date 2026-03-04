# ADR-0050: ComfyUI default egress baseline and manager log compatibility

## Status
Accepted

## Context
In `rootless-dev`, ComfyUI-Manager could not reliably fetch registry metadata or install missing nodes.
Proxy logs showed explicit denies for `api.comfy.org`, and existing runtime allowlists were not auto-updated when the template changed.

Some ComfyUI-Manager UI paths also still expect a legacy log filename (`comfyui.log`), while recent ComfyUI runs write per-port logs (for example `comfyui_8188.log`).

## Decision
- Extend the canonical default allowlist (`examples/core/allowlist.txt`) with ComfyUI-related baseline domains:
  - `api.comfy.org`
  - `registry.comfy.org`
  - `docs.comfy.org`
  - `blog.comfy.org`
  - `download.pytorch.org`
- Update `deployments/core/init_runtime.sh` to append any missing baseline entries from the template into an existing runtime allowlist, without removing operator custom entries.
- Add a compatibility symlink in the ComfyUI image entrypoint so `/comfyui/user/comfyui.log` points to the per-port log file (`/comfyui/user/comfyui_<port>.log`) when missing.
- Extend `agent doctor` to flag missing mandatory ComfyUI registry domains (`api.comfy.org`, `registry.comfy.org`) when ComfyUI is running.

## Consequences
- Existing installations receive missing baseline domains on the next runtime init (`agent up` / `agent update`) instead of requiring manual allowlist edits.
- ComfyUI-Manager can use official Comfy registry endpoints through the proxy by default.
- Log viewers relying on `comfyui.log` remain compatible with current ComfyUI log naming.
- Operators can still apply a stricter policy by overriding runtime allowlist contents after bootstrap.
