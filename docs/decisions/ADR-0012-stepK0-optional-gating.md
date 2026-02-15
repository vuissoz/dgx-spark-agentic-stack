# ADR-0012: Step K0 optional module gating

## Status
Accepted

## Context
Optional modules must stay disabled by default and must not be deployable when baseline compliance is red.

## Decision
- Add `compose/compose.optional.yml` with an `optional-sentinel` service under Compose profile `optional`.
- Extend `agent up` behavior:
  - run optional modules only when explicitly requested via `agent up optional`,
  - execute a doctor gate before optional deployment,
  - refuse deployment when doctor is red,
  - allow intentional bypass only through `AGENTIC_SKIP_OPTIONAL_GATING=1`.
- Ensure `agent up all` excludes optional modules by default.
- Add `tests/K0_optional_gating.sh` to validate refusal on red doctor and success on green doctor.

## Consequences
- Optional services cannot silently bypass baseline controls.
- Production-like default behavior remains conservative.
- Operators keep an explicit opt-out knob for controlled debugging scenarios.
