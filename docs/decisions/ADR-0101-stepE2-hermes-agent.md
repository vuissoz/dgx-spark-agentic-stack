# ADR-0101 — Step E2: `agentic-hermes` first-class agent integration

## Status
Accepted

## Context
Step E2 requires a fifth persistent core agent service, `agentic-hermes`, derived from `NousResearch/hermes-agent` with the same confinement baseline as the existing CLI agents.

The stack must keep deterministic routing through `ollama-gate`, persist Hermes state under `${AGENTIC_ROOT}/hermes/state`, and stay operational in constrained egress environments by pinning the upstream source revision explicitly.

## Decision
- Add `agentic-hermes` in `compose/compose.agents.yml` with:
  - non-root user, `read_only`, `tmpfs /tmp`, `cap_drop: [ALL]`, `no-new-privileges:true`;
  - mounts:
    - `${AGENTIC_ROOT}/hermes/state:/state`
    - `${AGENTIC_ROOT}/hermes/logs:/logs`
    - `${AGENTIC_HERMES_WORKSPACES_DIR}:/workspace`
  - the same gate/proxy/MCP baseline as the other core agents.
- Extend the shared agent image to install Hermes from a pinned upstream checkout:
  - repository: `https://github.com/NousResearch/hermes-agent.git`
  - ref: `v2026.4.3`
  - commit SHA: `abf1e98f6253f6984479fe03d1098173a9b065a7`
  - installation mode: local Python venv with extras `pty,cli`
- Ship `/usr/local/bin/hermes` wrapper:
  - delegates to the real Hermes binary when installation succeeded;
  - exposes deterministic fallback behavior for `--version` and `config path` when the real binary is absent.
- Extend the shared agent entrypoint:
  - for `AGENT_TOOL=hermes`, reconcile `HERMES_HOME=/state/home/.hermes`;
  - generate managed `config.yaml` and `.env` routing Hermes to `http://ollama-gate:11435/v1`;
  - preserve the tmux-backed `/workspace` operator contract used by `./agent hermes <project>`.

## Consequences
- `agentic-hermes` becomes a first-class agent surface with `agent ls`, `agent hermes`, `agent stop hermes`, doctor coverage, and Git-forge bootstrap parity.
- Hermes configuration is stack-managed and deterministic; local unmanaged edits under `HERMES_HOME` are overwritten on startup.
- Release traceability now includes pinned Hermes upstream source inputs inside the agent base image build fingerprint.
