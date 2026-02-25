# ADR-0010: Step I ComfyUI (GPU UI, local-only bind)

## Status
Accepted

## Context
Step I requires a ComfyUI web service for image generation while keeping the security baseline:
- no public bind (`127.0.0.1` host bind only),
- persistent model/input/output/user paths under `/srv/agentic/comfyui`,
- explicit GPU enablement with a low-priority profile marker,
- compatibility with controlled egress posture.

## Decision
- Extend `compose/compose.ui.yml` with `comfyui`:
  - image built locally as `agentic/comfyui:local` from `deployments/images/comfyui/Dockerfile`,
  - source checkout from `https://github.com/comfyanonymous/ComfyUI` at build time (`COMFYUI_REF`, default `master`),
  - install `ComfyUI-Manager` at image build time from `https://github.com/ltdrdata/ComfyUI-Manager` (`COMFYUI_MANAGER_REF`, default `main`) to expose built-in model management on first startup,
  - include a minimal C toolchain (`gcc` + `libc6-dev`) in build dependencies so `PyOpenGL-accelerate` can be compiled on `aarch64` when no prebuilt wheel is available,
  - `comfyui` service stays on the internal network only;
  - host bind `127.0.0.1:${COMFYUI_HOST_PORT:-8188}:8188` is published by a dedicated loopback reverse-proxy sidecar (`comfyui-loopback`) attached to both `agentic` and `agentic-egress`,
  - GPU request enabled (`gpus: all`),
  - low-priority GPU profile marker (`AGENTIC_GPU_PROFILE=lowprio`, `agentic.gpu-profile=lowprio`),
  - data volumes:
    - `${AGENTIC_ROOT}/comfyui/models:/comfyui/models`
    - `${AGENTIC_ROOT}/comfyui/input:/comfyui/input`
    - `${AGENTIC_ROOT}/comfyui/output:/comfyui/output`
    - `${AGENTIC_ROOT}/comfyui/user:/comfyui/user`
  - hardening baseline (`read_only: true`, `tmpfs: /tmp`, `cap_drop: [ALL]`, `no-new-privileges`).
- Extend `deployments/ui/init_runtime.sh` to create ComfyUI runtime directories.
- Add `tests/I1_comfyui.sh`:
  - verifies local-only bind, API availability, and GPU device request wiring,
  - verifies proxy egress posture (direct egress blocked, proxy path usable),
  - performs a best-effort workflow smoke generation when a checkpoint is available.

## Consequences
- ComfyUI is available without widening host exposure.
- The stack no longer depends on a non-existent/unofficial prebuilt ComfyUI image registry path.
- GPU usage is explicit and traceable as a low-priority workload.
- Model/output persistence is explicit and auditable under `/srv/agentic`.
- Smoke generation is deterministic only when at least one checkpoint exists locally.

## Notes
- The local build approach follows the same deployment principle described by John Aldred ("Running ComfyUI in Docker on Windows or Linux"): build your own container from upstream ComfyUI sources, then run with mounted model/input/output paths.
