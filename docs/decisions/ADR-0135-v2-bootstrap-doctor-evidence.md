# ADR-0135: Bootstrap-doctor evidence producer for v2

Date: 2026-07-09

Status: accepted

## Context

The v2 static evaluator can consume evidence and write artifact bundles, but the first implementation only used hand-authored fixture evidence in tests.

The next step is a repo-owned producer for the first walking-skeleton journey, `bootstrap-doctor`, without claiming that the full v2 walking skeleton is complete.

## Decision

Add `scripts/produce_v2_bootstrap_evidence.py`.

By default it performs bounded local checks:

- the v2 spec scaffold validates;
- the operator entrypoint, doctor script, release snapshot, rollback, release validator, v2 spec validator, and v2 evaluator exist;
- Compose policy files do not contain forbidden `docker.sock` mounts or public bind patterns;
- tracked runtime configuration files under `compose/`, `deployments/`, and `evaluation/` do not contain obvious non-example secret assignments.

Default output marks `bootstrap-doctor` as `partial`, because static local checks do not prove that a deployed stack bootstrapped and `./agent doctor` passed.

When run with `--run-doctor`, the producer executes `./agent doctor` with a timeout. Only static preflight plus a successful doctor run can promote `bootstrap-doctor` evidence to `pass`.

## Consequences

The evaluator now preserves `partial` evidence in artifacts while still requiring `pass` for P0 gates and P0 journeys. This lets implementation progress be visible without weakening promotion rules.

The remaining P0 walking-skeleton journeys still need their own evidence producers before a full evaluation can pass.
