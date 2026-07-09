# ADR-0141: Runtime-backed single-source-of-truth evidence for v2

## Status

Accepted.

## Context

The runtime-enhanced combined v2 evaluation already upgraded `p0-audit-correlated`, `p0-no-direct-backend-or-docker-sock`, and `p0-recovery-proven`. The remaining partial P0 gate was `p0-single-source-of-truth`.

The earlier context-isolation and recovery producers only offered non-authoritative local notes for this gate. That was enough to keep quarantine fail-closed, but not enough to prove that the current walking-skeleton runtime contracts have one authoritative mutable owner without ambiguous double-write state.

## Decision

Add `scripts/produce_v2_single_source_of_truth_evidence.py` and include it in the default combined evidence aggregation.

The producer supports two modes:

- default disposable-fixture mode, which creates a temporary `rootless-dev` `AGENTIC_ROOT`;
- host-backed target mode, which inspects or bootstraps an explicit `--agentic-root`.

Both modes use real repo-owned runtime commands and validators to prove ownership across the current walking-skeleton mutable contracts:

- `./agent llm backend remote` creates and updates the managed runtime env and backend state files;
- `deployments/releases/write_release_integrity.py` seals a release artifact directory;
- `deployments/releases/validate_release_artifacts.py` validates that sealed active release.

The producer marks `p0-single-source-of-truth=pass` only when all of the following hold:

- exactly one `deployments/runtime.env` owner exists and it contains no contradictory duplicate keys;
- exactly one `gate/state/llm_backend.json` owner exists;
- exactly one `gate/state/llm_backend_runtime.json` owner exists and it is coherent with the policy file;
- exactly one `deployments/current` owner exists and it points to one sealed, valid active release directory.

Test hooks create contradictory duplicate keys and shadow owner files so the evidence fails closed on ambiguous ownership. The host-backed path is threaded through `scripts/aggregate_v2_evidence.py` so the combined evaluator can consume explicit target-root ownership proof, and `scripts/run_v2_live_single_source_of_truth.py` provides the operator-facing live-target workflow.

## Consequences

The runtime-enhanced combined v2 evaluation can now pass all mandatory P0 gates and all four current P0 journeys, producing a `pareto` decision in the static evaluator when bootstrap doctor evidence is also supplied.

Current limitation:

- the host-backed target can inspect or bootstrap an operator-selected runtime root, but it still does not prove the same ownership contract against a live deployed DGX host stack with running containers and real release history.

That limitation is acceptable for the current static walking-skeleton gate because the proof now supports an explicit host-backed target and still exercises the actual repository-owned mutable-state contracts and validators instead of simulated-only placeholders.
