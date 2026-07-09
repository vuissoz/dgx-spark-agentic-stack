# ADR-0138: Snapshot-restore-rollback evidence producer for v2

Date: 2026-07-09

Status: accepted

## Context

The v2 walking-skeleton evaluator has local evidence producers for bootstrap-doctor, context isolation, and model backend failure handling. The remaining P0 journey in the initial corpus is snapshot-restore-rollback.

The deployed v2 release and data migration machinery does not exist yet. This slice must therefore prove a local recovery oracle and artifact shape without claiming production rollback execution.

## Decision

Add `scripts/produce_v2_snapshot_restore_rollback_evidence.py`.

The producer creates a disposable runtime fixture, records a checkpoint state and release artifact, mutates both, restores state from the snapshot, and rolls `current` back to the exact checkpoint release. It emits `pass` only when the restored state digest and rollback release digest match the checkpoint.

Test hooks intentionally skip restore or corrupt rollback to prove the evidence producer fails closed.

## Consequences

The evidence is marked as `local_simulated_recovery_policy`. It proves deterministic restore and rollback semantics for the local oracle, not deployed stack recovery.

Future v2 work must replace or supplement this with real release artifacts, data snapshots, rollback commands, post-restore doctor evidence, and failure injection against a deployed v2 runtime.
