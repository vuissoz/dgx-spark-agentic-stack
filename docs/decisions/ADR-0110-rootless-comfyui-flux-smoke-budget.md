# ADR-0110: Rootless ComfyUI Flux smoke requires a dedicated memory floor

## Context

The stack already exposed a Flux.1-dev bootstrap helper, but it did not prove that
ComfyUI could actually execute a real Flux workflow end-to-end in `rootless-dev`.

When running a real Flux.1-dev prompt on the active rootless stack, the prompt was
accepted and the backend then restarted mid-execution. The deployed ComfyUI
container was capped at `AGENTIC_LIMIT_COMFYUI_MEM=4g`, which is too small for a
reliable Flux smoke even when the GPU backend is available.

At the same time, the bootstrap helper still tracked legacy paths
(`checkpoints/`, `clip/`) instead of the runtime paths used by current ComfyUI
Flux nodes (`diffusion_models/`, `text_encoders/`).

## Decision

- Raise the dedicated `rootless-dev` ComfyUI memory default from `4g` to `110g`.
- Keep the generic `AGENTIC_LIMIT_UI_MEM` rootless default unchanged; the Flux
  requirement is specific to ComfyUI, not all UI services.
- Align the Flux bootstrap helper with actual ComfyUI runtime targets:
  - `diffusion_models/flux1-dev.safetensors`
  - `vae/ae.safetensors`
  - `text_encoders/clip_l.safetensors`
  - `text_encoders/t5xxl_fp16.safetensors`
- Preserve compatibility with previous local layouts through legacy symlinks.
- Add a dedicated automated test that:
  - verifies required Flux assets exist or downloads missing ones,
  - submits the example Flux prompt to ComfyUI,
  - fails if the ComfyUI container restarts during execution,
  - validates that a PNG image is actually written.

## Consequences

- `rootless-dev` gets a realistic baseline for Flux smoke validation instead of a
  bootstrap-only path that can pass while real inference crashes.
- Operators keep an explicit override path through `AGENTIC_LIMIT_COMFYUI_MEM` if
  they need a smaller or larger budget.
- Flux asset bootstrap now matches the ComfyUI nodes used by the runtime, making
  the helper and tests meaningful for actual generation.
