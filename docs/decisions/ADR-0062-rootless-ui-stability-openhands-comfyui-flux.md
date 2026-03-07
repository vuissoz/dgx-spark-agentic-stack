# ADR-0062: Rootless UI stability for OpenHands conversations and ComfyUI Flux bootstrap

## Status
Accepted

## Context

In `rootless-dev`, two operator-facing issues were observed:

1. OpenHands new conversation startup could fail intermittently with container restart.
   - Evidence: Docker events reported `oom` + `die` (`exit 137`) on `agentic-dev-openhands-1` during repeated app-conversation starts.
2. ComfyUI Journal/terminal stayed in loading state.
   - Evidence: `comfyui-loopback` returned HTTP `400` on `GET /ws`, indicating websocket upgrade was not forwarded.
3. Flux.1-dev setup was not operator-friendly.
   - No built-in stack command existed to bootstrap required model layout and remote downloads.

## Decision

1. OpenHands process-sandbox runtime:
   - add bounded per-user process sandbox capacity in the patched `ProcessSandboxService`,
   - configure capacity with `OH_PROCESS_SANDBOX_MAX_ACTIVE` (default `2`),
   - set non-zero startup poll frequency (`OH_APP_CONVERSATION_SANDBOX_STARTUP_POLL_FREQUENCY=1`),
   - raise dedicated OpenHands memory default (`AGENTIC_LIMIT_OPENHANDS_MEM`) to increase headroom in `rootless-dev`.

2. ComfyUI loopback proxy:
   - enable websocket upgrade forwarding (`Upgrade`/`Connection`) in `comfyui-loopback`,
   - keep loopback-only exposure and hardening posture unchanged.

3. Flux.1-dev operator flow:
   - add `agent comfyui flux-1-dev` command and script:
     - creates deterministic model layout + manifest under `${AGENTIC_ROOT}/comfyui/models`,
     - optionally downloads Flux.1-dev assets from Hugging Face (`--download`),
     - probes required remote endpoints used by manager/bootstrap unless disabled.

4. ComfyUI image GPU readiness:
   - install CUDA PyTorch wheels in image build by default (`cu124`) to avoid CPU-only runtime fallback on GPU-capable hosts.

## Consequences

- New OpenHands conversations remain stable under normal single-user usage in rootless mode.
- ComfyUI Journal websocket works through loopback proxy.
- Flux.1-dev bootstrap becomes reproducible and scriptable from the `agent` wrapper.
- Operators still need HF license acceptance/token for gated Flux.1-dev assets.
