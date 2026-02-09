# ADR-0001: Step 0 harness and path conventions

## Status
Accepted

## Context
Step 0 requires a working `agent` command and idempotent shell tests before the stack services are implemented.

The target runtime layout is anchored in `/srv/agentic`, but repository tests must run from a fresh clone without requiring root privileges.

## Decision
- Provide `agent` as a repo-local entrypoint (`./agent`) delegating to `scripts/agent.sh`.
- Default runtime path remains `/srv/agentic` via `AGENTIC_ROOT`.
- Allow path/project overrides via environment variables:
  - `AGENTIC_ROOT`
  - `AGENTIC_COMPOSE_PROJECT`
  - `AGENTIC_TEST_DIR`
  - `AGENTIC_COMPOSE_DIR`
- Implement step-0 test harness with:
  - `tests/lib/common.sh`
  - `tests/00_harness.sh`
  - `tests/A_smoke.sh`

## Consequences
- Operators keep a single command (`agent`) from day one.
- CI and local dev can validate step 0 without touching `/srv/agentic` yet.
- Future steps can keep the same command contract while adding real compose files and compliance checks.
