# ADR-0134: Static v2 evaluation runner and artifact writer

Date: 2026-07-09

Status: accepted

## Context

ADR-0133 created the initial v2 evaluation specs, but there was no executable path that consumed them or produced the artifact layout required by `PLAN.md` section 15.4.9.

The next step must remain local-only and safe to run without a deployed DGX stack, while still preserving the P0 rule that missing evidence is not a pass.

## Decision

Add `scripts/run_v2_evaluation.py` as the first v2 evaluation runner.

The runner:

- validates the v2 spec scaffold before doing any evaluation work;
- consumes an optional JSON evidence file for mandatory P0 gates and visible journeys;
- writes `evaluation.json`, `manifest.json`, `gates.json`, `runtime.json`, `engineering.json`, `pareto.json`, `recovery.json`, `report.md`, and empty `logs/`, `traces/`, `attempts/` directories;
- defaults artifacts outside the repo under `${AGENTIC_V2_EVALUATION_ARTIFACT_ROOT}`, `${AGENTIC_ROOT}/artifacts/evaluations`, or `~/.local/share/agentic/artifacts/evaluations`;
- redacts secret-like evidence keys before writing artifacts;
- returns `0` only when all mandatory P0 gate and journey evidence is present and passing;
- returns `2` after writing quarantine artifacts when P0 evidence is missing.

## Consequences

The v2 branch now has an executable local artifact contract. It does not yet execute deployed journeys, compute real Wilson intervals, compare v1/v2 non-inferiority, or promote candidates.

Those runtime capabilities are follow-up work built on top of this artifact writer rather than replacements for it.
