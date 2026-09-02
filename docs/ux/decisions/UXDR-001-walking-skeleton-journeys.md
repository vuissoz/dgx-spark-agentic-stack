# UXDR-001 — Walking skeleton journeys as v2 validation baseline

**Status:** accepted  
**Author:** Platform team  
**Date:** 2026-07-13  
**Re-evaluation condition:** When M3U gate validation reveals the walking skeleton is insufficient for real user workflows.  

## Capacity and user path concerned
All core platform capabilities: bootstrap, model access, agent execution, workspace isolation, recovery, rollback.

## User problem
The v2 rewrite must prove it can deliver on the PLAN.md product contract (§1.1) before expanding scope. Users need confidence that the rewritten platform can be deployed, used, and recovered without infrastructure expertise.

## Affected profiles
- Administrator (deployment, recovery)
- Developer/agent user (execution, workspace isolation)

## v1 observations to avoid reproducing
- v1 required Docker knowledge for basic operations (`docker compose up`, port inspection).
- v1's doctor script was not deterministic across environments.
- v1's rollback was described but not fully tested as a user-facing workflow.

## Alternatives considered
1. **Walking skeleton with 5 P0 journeys** (chosen) — Bootstrap-doctor, context-isolation, model-backend-failure, snapshot-restore-rollback, codex-repo-change. Provides concrete oracles for each critical capability.
2. **Full feature parity with v1 first** — Would delay validation indefinitely and risk re-implementing v1 UX pitfalls.
3. **Minimal bootstrap only** — Insufficient to prove recovery, isolation, and agent execution work together.

## Decision taken and justification
Adopt 5 walking skeleton journeys as the mandatory validation baseline (PLAN.md §15.4.5):

1. **bootstrap-doctor** (P0) — Platform deploys, healthchecks pass, release metadata is recorded.
2. **context-isolation** (P0) — Personal and project workspaces are isolated; negative leakage checks fail closed.
3. **model-backend-failure** (P0) — A backend failure triggers explicit fallback or actionable refusal with recovery evidence.
4. **snapshot-restore-rollback** (P0) — Snapshot, mutation, restore, and release rollback return the platform to the selected checkpoint.
5. **codex-repo-change** (P1) — Codex can change files, run tests, commit, and push within an authorized repository.

This decision follows PLAN.md §15.4.5 which explicitly mandates these journeys and ties them to P0 gates in §15.4.2. The evidence system (evaluation/spec/*, scripts/produce_v2_*.py) implements the validation mechanism for these journeys.

## Known consequences
- Each journey requires its own evidence producer script.
- The static evaluator must consume all 5 journey results for a `promote` decision.
- Runtime journeys (on actual DGX hardware) require separate validation beyond the local simulation producers.

## Applicable directive(s)
- DXR-001 (simplicity over exhaustiveness) — Start with minimum viable validation before expanding.
- DXR-004 (P0 security gates non-negotiable) — context-isolation and model-backend-failure are P0 journeys.

## Re-evaluation conditions
- If M3U gate validation reveals missing journeys for real user workflows.
- If any journey's oracle is found to be ambiguous or insufficiently discriminating.

## Associated acceptance tests
- `tests/V2_bootstrap_evidence.sh` — Validates bootstrap-doctor evidence pipeline
- `tests/V2_context_isolation_evidence.sh` — Validates context-isolation evidence pipeline  
- `tests/V2_model_backend_failure_evidence.sh` — Validates model-backend-failure evidence pipeline
- `tests/V2_snapshot_restore_rollback_evidence.sh` — Validates snapshot-restore-rollback evidence pipeline
- `tests/V2_single_source_of_truth_evidence.sh` — Validates single-source-of-truth P0 gate
- `scripts/produce_v2_bootstrap_evidence.py` and equivalent producers
