# ADR-0008: Step G observability stack (Prometheus, Grafana, Loki, exporters)

## Status
Accepted

## Context
Step G requires an observability baseline for host and container telemetry, logs, and GPU metrics, while preserving the security posture:
- no public host exposure,
- no docker socket mount,
- explicit runtime persistence under `/srv/agentic/monitoring`.

## Decision
- Add `compose/compose.obs.yml` with:
  - `prometheus`, `grafana`, `loki`, `promtail`,
  - `node-exporter`, `cadvisor`, `dcgm-exporter`.
- Host binds remain loopback-only:
  - Prometheus: `127.0.0.1:${PROMETHEUS_HOST_PORT:-19090}:9090`
  - Grafana: `127.0.0.1:${GRAFANA_HOST_PORT:-13000}:3000`
  - Loki: `127.0.0.1:${LOKI_HOST_PORT:-13100}:3100`
- Add runtime bootstrap `deployments/obs/init_runtime.sh`:
  - creates monitoring directories under `${AGENTIC_ROOT}/monitoring`,
  - installs default configs from `examples/obs/`,
  - applies Grafana uid ownership when run as root.
- Add config templates:
  - `examples/obs/prometheus.yml`
  - `examples/obs/loki-config.yml`
  - `examples/obs/promtail-config.yml`
- Wire `agent up obs` to run `deployments/obs/init_runtime.sh` before deploy.
- Add test `tests/G1_obs_up.sh` covering:
  - local-only binds for obs host ports,
  - Grafana endpoint availability,
  - Prometheus targets API health,
  - Loki ingest/query smoke,
  - DCGM metrics presence (with explicit opt-out `AGENTIC_SKIP_DCGM_CHECK=1`).

## Consequences
- Observability stack is reproducible and deployable through the `agent` wrapper.
- GPU telemetry is verified when hardware/runtime support is present.
- Remaining host-specific validation (GPU/runtime permissions) is captured by Step G tests.
