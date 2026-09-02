# ADR-0012: Step K0 optional module gating

## Status
Accepted

## Context
Optional modules must stay disabled by default and should expose baseline compliance problems before deployment.

## Decision
- Add `compose/compose.optional.yml` with an `optional-sentinel` service under Compose profile `optional`.
- Extend `agent up` behavior:
  - run optional modules only when explicitly requested via `agent up optional`,
  - execute a doctor check before optional deployment,
  - emit the doctor output and a warning when doctor is red, then continue,
  - retain `AGENTIC_SKIP_OPTIONAL_GATING=1` as an explicit way to skip the check entirely.
- Ensure `agent up all` excludes optional modules by default.
- Add `tests/K0_optional_gating.sh` to validate refusal on red doctor and success on green doctor.

## Consequences
- Optional services report baseline problems without creating a deployment deadlock.
- Module-specific prerequisite checks remain blocking.
- Operators keep an explicit opt-out knob for controlled debugging scenarios.
