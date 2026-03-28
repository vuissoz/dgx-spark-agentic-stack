# ADR-0088: Agent Start/Stop Isolation Contract

## Status
Accepted

## Context

Issue `dgx-spark-agentic-stack-30x` asks whether targeted `agent start/stop` cycles are safe for the agent containers in `rootless-dev`, and whether one agent can be stopped independently without cascading failures.

The CLI entrypoints are intentionally thin:

- `agent stop <tool>` maps to the matching Compose service and stops only that container set.
- `agent start <target>` and `agent stop <target>` now cover both attachable CLI agents and selected user-facing service bundles.
- `agent stop/start service <service...>` and `agent stop/start container <container...>` call Docker directly on the selected project resources.

The agent services (`agentic-claude`, `agentic-codex`, `agentic-opencode`, `agentic-vibestral`) do not declare Compose-level `depends_on` relationships on each other. Their coupling is runtime-only through shared core endpoints on the internal Docker network (`ollama-gate`, `gate-mcp`, `egress-proxy`, `unbound`).

## Decision

We treat targeted stop/start of a single agent container or bundled user-facing surface as a supported operation, with these explicit semantics:

- stopping one agent must not stop peer agent containers;
- stopping one agent must not stop shared core services;
- starting an already-created agent container does not auto-start missing dependencies; operators must keep `core` up separately;
- after restart, the agent entrypoint is responsible for recreating the persistent tmux session if it was lost.
- bundled targets are explicit:
  - `openclaw` stops/starts `openclaw`, `openclaw-gateway`, `openclaw-provider-bridge`, `openclaw-sandbox`, and `openclaw-relay` together;
  - `comfyui` stops/starts `comfyui` and `comfyui-loopback` together.

## Consequences

- The repository now includes `tests/L11_agent_start_stop_isolation.sh` to verify the contract against a disposable `rootless-dev` stack.
- The test cycles real agent services using all supported entrypoints (`agent stop <tool>`, `agent stop/start service`, `agent stop/start container`).
- The test asserts peer/core health remains intact and that the restarted container recreates its tmux session contract before user attachment.
- The repository now also includes `tests/L12_surface_stop_isolation.sh` to cover user-facing stop/start targets (`openclaw`, `goose`, `openwebui`, `openhands`, `comfyui`) alongside the CLI agents in one disposable stack.
- `agent status` is now the per-container view for the compose project, while `agent ls` remains the target-oriented summary.
