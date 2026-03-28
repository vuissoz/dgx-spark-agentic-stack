# ADR-0087: Onboarding-managed observability retention policy

## Status

Accepted

## Context

Issue `dgx-spark-agentic-stack-im5` requires onboarding to collect a retention duration and a maximum disk budget for observability data, then enforce that policy across the stack.

The current stack already persists monitoring data under `${AGENTIC_ROOT}/monitoring/{prometheus,loki}`, but it did not expose an operator-level contract for:
- maximum age of metrics/logs,
- maximum disk budget reserved for observability,
- deterministic runtime config generated from onboarding values,
- doctor/compliance validation of the effective policy.

## Decision

We introduce a stack-level observability retention contract:

- operator inputs:
  - `AGENTIC_OBS_RETENTION_TIME`
  - `AGENTIC_OBS_MAX_DISK`
- derived/runtime values:
  - `AGENTIC_PROMETHEUS_DISK_BUDGET`
  - `AGENTIC_LOKI_DISK_BUDGET`
  - `PROMETHEUS_RETENTION_TIME`
  - `PROMETHEUS_RETENTION_SIZE`
  - `LOKI_RETENTION_PERIOD`
  - `LOKI_MAX_QUERY_LOOKBACK`

Default profile values:
- `rootless-dev`: `7d`, `8GB`
- `strict-prod`: `30d`, `32GB`

Budget split policy:
- Prometheus gets 25% of the total observability disk budget.
- Loki gets 75% of the total observability disk budget.

Enforcement path:
- onboarding exports both operator inputs and derived values,
- Prometheus receives `--storage.tsdb.retention.time` and `--storage.tsdb.retention.size`,
- `deployments/obs/init_runtime.sh` writes a managed retention audit file and a managed Loki config,
- doctor verifies policy presence/coherence and current disk usage against the configured budget.

## Consequences

Positive:
- operators can tune retention without hand-editing compose/config files,
- rootless-dev gets safer defaults for local disks,
- Prometheus retention is hard-enforced by runtime flags,
- Loki retention becomes explicit and auditable in generated config.

Trade-offs:
- Loki filesystem mode does not natively enforce a hard size cap; the stack therefore combines time-based Loki retention with doctor budget validation and a separate explicit Loki budget value for audit/operations.
- `deployments/obs/init_runtime.sh` now owns the generated `loki-config.yml` so retention stays deterministic.
