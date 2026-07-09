# ADR-0133: Initial v2 evaluation spec scaffold

Date: 2026-07-09

Status: accepted

## Context

`PLAN.md` makes the v2 implementation dependent on explicit evaluation specifications, visible corpora, engineering tasks, recovery evidence, and promotion gates. Those paths were normative but not yet materialized in the repository.

The first v2 implementation slice needs to be small, verifiable without a deployed DGX stack, and aligned with M0/M1. It must not disturb the existing v1 operator path.

## Decision

Create the initial v2 evaluation scaffold under `evaluation/`:

- `evaluation/spec/{capabilities,architecture,metrics,promotion,recovery,retention}.yaml`
- `evaluation/corpora/visible/v2-walking-skeleton-v0/manifest.yaml`
- `evaluation/tasks/engineering/v2-changeability-v0/manifest.yaml`

The files use JSON-subset YAML. This keeps the extension and semantics expected by the plan while allowing validation with Python's standard library and no new dependency.

Add `scripts/validate_v2_evaluation_specs.py` and `tests/V2_evaluation_specs.sh` to enforce that the scaffold remains present, parseable, and tied to the five walking-skeleton journeys from the plan.

## Consequences

Future v2 slices have a concrete capability and evaluation contract to extend instead of adding undocumented behavior.

The scaffold is intentionally minimal. It does not yet execute journeys, compute TPSR, compare v1/v2 results, or produce promotion artifacts. Those belong in later implementation slices once the walking skeleton starts to exist.
