# ADR-0007: Step F operator CLI, digest snapshots, rollback, and doctor gating

## Status
Accepted

## Context
Step F requires operational controls for day-2:
- single entrypoint operator actions (`agent`),
- release traceability from floating tags (`:latest`) to pinned runtime state,
- deterministic rollback,
- stronger compliance checks in `agent doctor`.

## Decision
- Extend `agent` (`scripts/agent.sh`) with:
  - `agent <tool> [project]` for tmux attach with project workspace selection,
  - `agent ls`, `agent stop <tool>`,
  - `agent update` (pull/redeploy + snapshot),
  - `agent rollback all <release_id>`,
  - runtime config persistence in `${AGENTIC_ROOT}/deployments/runtime.env`.
- Add release scripts:
  - `deployments/releases/snapshot.sh`:
    - captures compose effective config,
    - records per-service configured image, resolved image ID, repo digest, health/state,
    - writes release artifacts under `${AGENTIC_ROOT}/deployments/releases/<timestamp>/`,
    - updates `${AGENTIC_ROOT}/deployments/current` symlink.
  - `deployments/releases/rollback.sh <release_id>`:
    - generates image-pinning compose override from release manifest,
    - redeploys with `--no-build`,
    - updates changes log and `current` symlink.
- Strengthen `agent doctor` (`scripts/doctor.sh`) with checks for:
  - no public bind on critical ports,
  - DOCKER-USER policy enforcement,
  - proxy/egress policy (direct egress blocked from toolbox),
  - core critical service health,
  - agent container confinement + proxy env,
  - active release manifest presence.
- Add tests:
  - `tests/F1_agent_cli.sh`
  - `tests/F2_update_rollback.sh`
  - `tests/F3_doctor.sh`

## Consequences
- Operator workflows become reproducible without exposing extra host surfaces.
- Rollback target is explicit and auditable by release ID.
- `agent doctor` now acts as a practical gate for security/compliance drift.
