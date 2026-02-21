# ADR-0006: Step E persistent CLI agents with tmux and confined runtime

## Status
Accepted

Superseded in part by `ADR-0028-stepE2-vibestral-agent.md` for the fourth baseline agent service (`agentic-vibestral`).

## Context
Step E requires long-lived CLI agent containers (`claude`, `codex`, `opencode`) with persistent state/workspaces, strict confinement, and controlled LLM/proxy wiring through previously deployed core services.

## Decision
- Add a shared image at `deployments/images/agent-cli-base/Dockerfile`:
  - packages: `bash`, `tmux`, `git`, `curl`, `ca-certificates`;
  - default non-root user (`agent`);
  - entrypoint script (`deployments/images/agent-cli-base/entrypoint.sh`) that keeps a named tmux session alive.
- Add `compose/compose.agents.yml` with three services:
  - `agentic-claude`, `agentic-codex`, `agentic-opencode`;
  - `read_only: true`, `tmpfs: /tmp`, `cap_drop: [ALL]`, `no-new-privileges:true`;
  - per-tool persistent mounts under `${AGENTIC_ROOT}/<tool>/{state,logs,workspaces}`;
  - proxy and gate envs:
    - `OLLAMA_BASE_URL=http://ollama-gate:11435`
    - `HTTP_PROXY/HTTPS_PROXY=http://egress-proxy:3128`
    - `NO_PROXY=ollama-gate,unbound,egress-proxy,localhost,127.0.0.1`
  - host-network exposure: none.
- Add runtime bootstrap for agents volumes in `deployments/agents/init_runtime.sh`.
- Wire `agent up agents` to initialize agent runtime before compose deploy (`scripts/agent.sh`).
- Add tests:
  - `tests/E1_image_build.sh`
  - `tests/E2_agents_confinement.sh`

## Consequences
- Agent sessions are persistent and attachable through tmux semantics without docker socket access.
- Writable surfaces are reduced to `/state`, `/logs`, `/workspace`, and `/tmp`.
- Agents can only reach outbound resources through the core proxy path (or fail closed if denied).
