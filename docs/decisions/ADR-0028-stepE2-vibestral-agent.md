# ADR-0028 — Step E2: `agentic-vibestral` first-class agent integration

## Status
Accepted

## Context
Step E requires a fourth persistent agent service (`agentic-vibestral`) with the same confinement baseline as the existing CLI agents, plus Vibe CLI bootstrap persisted under `${AGENTIC_ROOT}/vibestral/state`.

The stack egress model is deny-by-default through proxy allowlists, so Vibe installation can fail in constrained environments if the upstream install endpoint is blocked.

## Decision
- Add `agentic-vibestral` in `compose/compose.agents.yml` with:
  - non-root user, `read_only`, `tmpfs /tmp`, `cap_drop: [ALL]`, `no-new-privileges:true`;
  - mounts:
    - `${AGENTIC_ROOT}/vibestral/state:/state`
    - `${AGENTIC_ROOT}/vibestral/logs:/logs`
    - `${AGENTIC_ROOT}/vibestral/workspaces:/workspace`
  - same gate/proxy env baseline as other agent containers.
- Extend the shared image to attempt official install:
  - `curl -LsSf https://mistral.ai/vibe/install.sh | bash`
  - store discovered real binary path in `/etc/agentic/vibe-real-path`.
- Ship `/usr/local/bin/vibe` wrapper:
  - delegates to real Vibe binary when present;
  - otherwise provides a deterministic fallback shim and supports `vibe --setup`.
- Extend agent entrypoint:
  - for `AGENT_TOOL=vibestral`, execute one-time `vibe --setup` with persisted marker under `/state/vibe/.setup-complete`.

## Consequences
- `agentic-vibestral` is deployable with the same hardening posture as other agents.
- `agent vibestral`, `agent ls`, `agent stop vibestral`, and doctor/test coverage become first-class.
- Bootstrap remains operational in restricted egress environments while still attempting official Vibe installation first.
