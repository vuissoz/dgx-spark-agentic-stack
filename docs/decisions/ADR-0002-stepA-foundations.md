# ADR-0002: Step A host foundations and testability switches

## Status
Accepted

## Context
Step A introduces host prerequisites and filesystem bootstrap centered on `/srv/agentic` with strict permissions.

Repository tests still need to run in non-root environments where:
- `/srv` may be unwritable,
- the `agentic` group may not exist,
- GPU tooling may be unavailable.

## Decision
- Implement bootstrap at `deployments/bootstrap/init_fs.sh` with defaults:
  - `AGENTIC_ROOT=/srv/agentic`
  - `AGENTIC_GROUP=agentic`
- Add explicit testability switches:
  - `AGENTIC_SKIP_GROUP_CREATE=1` for non-root dry runs
  - `AGENTIC_SKIP_HOST_PREREQS=1` for harness-only runs
  - `AGENTIC_SKIP_GPU_CONTAINER_TEST=1` for host checks without container GPU probe
  - `AGENTIC_SKIP_PORT_BIND_CHECK=1` for isolated harness execution
- Keep production behavior strict by default (no skip active unless explicitly set).

## Consequences
- Step A can be validated end-to-end on target DGX hosts with default settings.
- CI/local contributors can still run harness and scripted checks without weakening runtime defaults.
