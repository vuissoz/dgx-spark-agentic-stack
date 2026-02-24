# ADR-0035 — Step E1c: shared agent image ships a multi-agent CLI matrix

## Status
Accepted

## Context

Step E now expects the shared agent runtime (`agent-cli-base`) to be directly usable for multiple CLI agents, not only for generic shell development tooling.

The stack already enforces strict runtime confinement (`read_only`, non-root, no `docker.sock`, proxy-first egress). CLI installation must keep these constraints and remain operational in environments where upstream installers may be blocked by egress policies.

## Decision

- Extend `deployments/images/agent-cli-base/Dockerfile` to install, during image build:
  - `codex` (OpenAI),
  - `claude` (Anthropic Claude Code),
  - `opencode`,
  - `vibe`,
  - `openhands`,
  - `openclaw`.
- Keep install behavior configurable with `AGENT_CLI_INSTALL_MODE`:
  - `best-effort` (default): continue build and expose deterministic wrappers when upstream install fails.
  - `required`: fail image build on any CLI installation failure.
- Persist installation resolution in `/etc/agentic/<cli>-real-path` and `/etc/agentic/cli-install-status.tsv`.
- Ship wrappers for `codex`, `claude`, `opencode`, `openhands`, and `openclaw`, plus existing `vibe` wrapper behavior:
  - wrapper delegates to resolved real binary when available;
  - otherwise wrapper fails with an actionable message.
- Add per-service primary CLI contract in `compose/compose.agents.yml` (`AGENT_PRIMARY_CLI`) and verify in:
  - `tests/E2_agents_confinement.sh`,
  - `scripts/doctor.sh`.

## Consequences

- The shared CUDA/toolchain image becomes a true multi-agent CLI base, reusable across agent containers.
- Operators can choose between resilient builds (`best-effort`) and strict supply expectations (`required`).
- Runtime diagnostics now detect drift where an agent container starts without its declared primary CLI.
