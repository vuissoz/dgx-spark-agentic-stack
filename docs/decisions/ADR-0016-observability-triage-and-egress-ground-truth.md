# ADR-0016: Observability triage baseline with egress ground truth

## Status
Accepted

## Context
Operational incidents in agentic stacks are often caused by:
- provider throttling or outages (`429`, `5xx`, long-tail latency),
- egress/proxy/DNS failures,
- runtime pressure (CPU, memory, disk, OOM, restart storms).

Without consolidated, queryable evidence across application logs, egress logs, and runtime metrics, triage is slow and uncertain.

## Decision
- Keep the existing observability stack (`Prometheus`, `Grafana`, `Loki`, `Promtail`, `node-exporter`, `cadvisor`, `dcgm-exporter`).
- Promote proxy logs to first-class signals by ingesting `${AGENTIC_ROOT}/proxy/logs/access.log*` with promtail.
- Parse key egress fields in promtail (`src_ip`, `http_status`, `method`, `squid_result`, `dest_host`) to support immediate LogQL queries and dashboards.
- Add default Prometheus alert rules template for high-value runtime signals:
  - host disk pressure,
  - container restart storm,
  - container OOM events,
  - critical scrape target down.
- Add runbook `docs/runbooks/observability-triage.md` with concrete triage queries and incident flow.

## Consequences
- Operators can quickly answer "what is slow/failing/leaking/retrying" with evidence.
- Egress behavior is auditable from a single query path (Loki), not only from ad hoc host shell access.
- Alerting starts with low-noise runtime conditions and can be extended with Grafana Loki rules for provider-specific 429/5xx thresholds.
