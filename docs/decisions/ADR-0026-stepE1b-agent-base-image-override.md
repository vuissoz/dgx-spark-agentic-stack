# ADR-0026 — Step E1b: Runtime override for shared agent base image

## Context

Step E1b requires a safe way to customize the shared agent base image without forking compose files:
- keep a secure fallback (`deployments/images/agent-cli-base/Dockerfile`),
- allow runtime overrides for image tag, Dockerfile path, and build context,
- keep agent hardening unchanged (`read_only`, `cap_drop=ALL`, `no-new-privileges`, no `docker.sock`).

## Decision

1. Introduce runtime variables consumed by `compose/compose.agents.yml`:
   - `AGENTIC_AGENT_BASE_IMAGE`,
   - `AGENTIC_AGENT_BASE_BUILD_CONTEXT`,
   - `AGENTIC_AGENT_BASE_DOCKERFILE`.
2. Extend runtime handling (`scripts/lib/runtime.sh`, `scripts/agent.sh`) to:
   - persist these values in `${AGENTIC_ROOT}/deployments/runtime.env`,
   - display them in `agent profile`,
   - build/rebuild the shared agent image during `agent up agents` and `agent update` using stamp-based fingerprinting.
3. Enforce a minimal contract after build:
   - non-root image user,
   - explicit entrypoint,
   - required toolchain (`bash`, `tmux`, `git`, `curl`).
4. Add test coverage with `tests/E1b_agent_base_image_override.sh` for:
   - default fallback behavior,
   - custom override behavior and explicit image tag,
   - unchanged confinement invariants on running agent containers.

## Consequences

- Operators can maintain custom agent base images while keeping a deterministic fallback.
- Release traceability remains explicit through custom image tagging and runtime env persistence.
- Security posture remains fail-closed if a custom image breaks the minimal runtime contract.
