# ADR-0009: Step H UI services (OpenWebUI + OpenHands, hardened and local-only)

## Status
Accepted

## Context
Step H adds user-facing web UIs while preserving constraints:
- loopback-only host exposure,
- no `docker.sock` mount (OpenHands included),
- controlled LLM path through `ollama-gate`.

## Decision
- Add `compose/compose.ui.yml` with:
  - `openwebui` on `127.0.0.1:${OPENWEBUI_HOST_PORT:-8080}`,
  - `openhands` on `127.0.0.1:${OPENHANDS_HOST_PORT:-3000}`.
- Apply baseline hardening on both services:
  - `read_only: true`, `tmpfs: /tmp`,
  - `cap_drop: [ALL]`,
  - `security_opt: [no-new-privileges:true]`.
- Keep OpenHands without docker socket:
  - no mount for `/var/run/docker.sock`,
  - runtime set to `process`.
- Route UI model access through `ollama-gate`:
  - OpenWebUI via OpenAI-compatible endpoint `http://ollama-gate:11435/v1`,
  - OpenHands via `LLM_BASE_URL=http://ollama-gate:11435/v1`.
- Add runtime bootstrap `deployments/ui/init_runtime.sh`:
  - creates `${AGENTIC_ROOT}/openwebui` and `${AGENTIC_ROOT}/openhands` trees,
  - installs env templates from `examples/ui/` with strict mode (`0600`).
- Wire `agent up ui` to run UI runtime bootstrap before deploy.
- Add tests:
  - `tests/H1_openwebui.sh`
  - `tests/H2_openhands.sh`

## Consequences
- UI access remains Tailscale/host-loopback mediated only.
- OpenHands starts in a socketless posture by default.
- UI-to-gate connectivity is verifiable through gate logs.
