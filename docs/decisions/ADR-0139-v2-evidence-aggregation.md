# ADR-0139: Combined v2 evidence aggregation

Date: 2026-07-09

Status: accepted

## Context

The v2 repository has separate evidence producers for the four initial P0 walking-skeleton journeys, but `scripts/run_v2_evaluation.py` consumes one evidence file. Operators and future automation need one command that builds a combined evidence bundle for a full static evaluation pass.

## Decision

Add `scripts/aggregate_v2_evidence.py`.

The aggregator runs the default v2 evidence producers, merges their `gates` and `journeys`, records producer metadata under `runtime.producers`, and writes one `v2-combined-evidence.v0` JSON object.

The aggregator is conservative:

- producer failures make aggregation fail;
- duplicate gate evidence is aggregated conservatively using the worst observed status;
- conflicting duplicate journey evidence makes aggregation fail;
- existing evidence files can be merged with `--input`;
- default producers can be disabled for tests and future runtime-specific aggregation.

## Consequences

The static evaluator can now consume one combined walking-skeleton evidence file. The result is still expected to quarantine until partial gates such as deployed `bootstrap-doctor`, durable audit persistence, and source-of-truth proof are replaced with runtime-backed evidence.

This creates the first complete local static evaluation loop without weakening P0 promotion rules.
