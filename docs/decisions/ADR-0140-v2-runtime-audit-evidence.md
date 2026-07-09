# ADR-0140: Runtime-backed audit evidence for v2 static aggregation

## Status

Accepted.

## Context

The combined v2 static evidence bundle covers the four initial P0 walking-skeleton journeys, but promotion still remains quarantined because several mandatory gates are intentionally partial. `p0-audit-correlated` was one of those partial gates: the model-backend producer emitted only local audit-shape evidence, not proof that a runtime command produced durable, correlated operator evidence.

## Decision

`scripts/produce_v2_bootstrap_evidence.py --run-doctor` now promotes `p0-audit-correlated` only when the configured doctor command exits successfully and emits the explicit `doctor result: READY` marker. The resulting gate evidence is marked authoritative and includes the bounded doctor output.

The evidence aggregator now records whether each gate observation is authoritative. A failing observation still fails the gate. Otherwise, authoritative observations decide the aggregate gate status, while non-authoritative observations remain attached for audit but cannot downgrade stronger runtime proof.

`scripts/aggregate_v2_evidence.py --run-bootstrap-doctor` passes `--run-doctor` to the default bootstrap producer. This lets a combined evaluation artifact record `p0-audit-correlated=pass` when runtime doctor evidence is available, while still quarantining the candidate until the remaining partial P0 gates are upgraded.

## Consequences

Remaining partial P0 gates after this change:

- `p0-single-source-of-truth`: still static/local evidence; needs runtime proof of one mutable owner per v2 domain.
- `p0-recovery-proven`: still partial in the combined aggregate because bootstrap evidence only checks paths; full pass requires runtime snapshot, restore, rollback, and post-restore doctor proof.
- `p0-no-direct-backend-or-docker-sock`: still partial in the combined aggregate because bootstrap evidence only scans static compose policy; full pass requires deployed network/backend refusal evidence across all relevant runtime surfaces.

This change does not promote a full v2 candidate. It upgrades one gate with bounded runtime evidence and keeps the evaluator in quarantine when any P0 journey or gate remains partial.
