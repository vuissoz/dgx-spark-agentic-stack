# ADR-0010: Step I ComfyUI (GPU UI, local-only bind)

## Status
Accepted

## Context
Step I requires a ComfyUI web service for image generation while keeping the security baseline:
- no public bind (`127.0.0.1` host bind only),
- persistent model/input/output/user paths under `/srv/agentic/comfyui`,
- compatibility with controlled egress posture.

## Decision
- Extend `compose/compose.ui.yml` with `comfyui`:
  - image `ghcr.io/comfyanonymous/comfyui:latest`,
  - host bind `127.0.0.1:${COMFYUI_HOST_PORT:-8188}:8188`,
  - data volumes:
    - `${AGENTIC_ROOT}/comfyui/models:/comfyui/models`
    - `${AGENTIC_ROOT}/comfyui/input:/comfyui/input`
    - `${AGENTIC_ROOT}/comfyui/output:/comfyui/output`
    - `${AGENTIC_ROOT}/comfyui/user:/comfyui/user`
  - hardening baseline (`cap_drop: [ALL]`, `no-new-privileges`).
- Extend `deployments/ui/init_runtime.sh` to create ComfyUI runtime directories.
- Add `tests/I1_comfyui.sh`:
  - verifies local-only bind and API availability,
  - performs a best-effort workflow smoke generation when a checkpoint is available.

## Consequences
- ComfyUI is available without widening host exposure.
- Model/output persistence is explicit and auditable under `/srv/agentic`.
- Smoke generation is deterministic only when at least one checkpoint exists locally.
