# Runbook: Observability Triage (Fast Evidence Path)

This runbook is for answering quickly with evidence:
- what is slow,
- what is failing,
- what is retrying or rate-limited,
- what is bypassing or leaking egress,
- what is resource-starved or crash-looping.

## Signal Model

Use three layers together:

1. Application layer:
- OpenClaw/agent logs (container logs in Loki via promtail).
- Request IDs or correlation IDs if available in app logs.

2. Network egress layer:
- Squid access logs are treated as outbound ground truth.
- In this stack, promtail ingests `${AGENTIC_ROOT}/proxy/logs/access.log*`.
- Host telemetry mount sources are configurable via:
  - `PROMTAIL_DOCKER_CONTAINERS_HOST_PATH`
  - `PROMTAIL_HOST_LOG_PATH`
  - `NODE_EXPORTER_HOST_ROOT_PATH`
  - `CADVISOR_HOST_ROOT_PATH`
  - `CADVISOR_DOCKER_LIB_HOST_PATH`
  - `CADVISOR_SYS_HOST_PATH`
  - `CADVISOR_DEV_DISK_HOST_PATH`
  Check effective values with `./agent profile`.

3. Runtime layer:
- Prometheus metrics from `node-exporter`, `cadvisor`, `dcgm-exporter`, and service endpoints.
- Container restarts, OOM events, CPU/memory pressure, disk pressure.

## Prerequisites

1. Start core and observability stacks:

```bash
./agent up core,obs
./agent doctor
```

2. Confirm proxy logs exist on host:

```bash
ls -l "${AGENTIC_ROOT:-/srv/agentic}/proxy/logs/access.log"
```

3. Confirm promtail sees the egress-proxy stream in Grafana Explore:
- datasource: Loki
- query: `{job="egress-proxy"}`

## Rootless Ownership Drift (Strict -> Rootless)

If observability services restart-loop after switching from strict/rootful runs to `rootless-dev`, run:

```bash
export AGENTIC_PROFILE=rootless-dev
./agent up obs
```

`deployments/obs/init_runtime.sh` now auto-repairs legacy root-owned paths under `${AGENTIC_ROOT}/monitoring` in `rootless-dev` before starting services.

Quick check:

```bash
find "${AGENTIC_ROOT}/monitoring" -mindepth 0 ! -writable -print -quit
```

Expected: no output.

## Immediate High-Signal Queries

Use these in Grafana Explore (Loki/Prometheus) or dashboard panels.

### 1) Top egress destinations (count)

LogQL:

```logql
topk(
  20,
  sum by (dest_host) (
    count_over_time({job="egress-proxy"}[10m])
  )
)
```

### 2) Egress 429 and 5xx rates

LogQL (`429`):

```logql
sum(count_over_time({job="egress-proxy", http_status="429"}[10m]))
```

LogQL (`5xx`):

```logql
sum(count_over_time({job="egress-proxy", http_status=~"5.."}[10m]))
```

### 3) Egress latency p95/p99

LogQL (milliseconds):

```logql
quantile_over_time(
  0.95,
  {job="egress-proxy"}
    | pattern "<ts> <duration_ms> <src_ip> <squid_result>/<http_status> <bytes> <method> <url> <user> <hierarchy>/<upstream> <mime>"
    | unwrap duration_ms [5m]
)
```

Repeat with `0.99` for p99.

### 4) Container restart storm

PromQL:

```promql
changes(container_start_time_seconds{container_label_com_docker_compose_project!=""}[15m])
```

### 5) OOM kills and disk pressure

PromQL (OOM):

```promql
increase(container_oom_events_total{container_label_com_docker_compose_project!=""}[15m])
```

PromQL (host root FS usage ratio):

```promql
(
  (node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}
  - node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"})
  / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}
)
```

## Recommended Starter Alerts

Prometheus rules template is provided at:
- `examples/obs/prometheus-alerts.yml`
- runtime path: `${AGENTIC_ROOT}/monitoring/config/prometheus-alerts.yml`

Included baseline alerts:
- host disk usage > 85% for 10m,
- container restart storm (>3 changes in 15m),
- container OOM events in the last 15m,
- scrape target down for critical jobs.

For provider-specific 429/5xx and timeout alerts, use Grafana Loki alert rules on `{job="egress-proxy"}`.

## Practical Incident Flow

1. Check egress error/latency first (`429`, `5xx`, p95/p99).
2. Correlate with runtime pressure (CPU/memory/OOM/restarts).
3. Confirm app-layer errors for impacted services (`./agent logs <service>` and Loki query).
4. If egress failures are destination-specific, verify `${AGENTIC_ROOT}/proxy/allowlist.txt` and proxy logs.

## Known Blind Spot to Avoid

If some components can reach the internet directly while others are proxy-forced, observability becomes partial and root-cause analysis slows down.

Prefer one explicit policy:
- either proxy-force all outbound traffic that should be observed,
- or block direct outbound and allow only sanctioned paths.
