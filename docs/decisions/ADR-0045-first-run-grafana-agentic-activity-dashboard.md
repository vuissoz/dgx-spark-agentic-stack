# ADR-0045: First-run Grafana provisioning for agentic activity dashboard

## Status
Accepted

## Context
Operators needed immediate observability on first startup without manual Grafana setup.
Requested coverage includes:
- per-agent and OpenWebUI model activity,
- tool-call activity,
- network activity,
- first-run availability of a usable dashboard.

The stack already exposes Prometheus/Loki, but lacked automatic datasources/dashboard provisioning and direct ingestion of gate and gate-mcp audit logs.

## Decision
- Add Grafana provisioning templates under `examples/obs/`:
  - `grafana-datasources.yml` (Prometheus + Loki),
  - `grafana-dashboards.yml` (file provider),
  - `grafana-dashboard-agentic-activity-overview.json` (UID `dgx-spark-activity`).
- Extend `deployments/obs/init_runtime.sh` to materialize those files under:
  - `${AGENTIC_ROOT}/monitoring/config/grafana/provisioning/...`
  - `${AGENTIC_ROOT}/monitoring/config/grafana/dashboards/...`
  on first run (`copy_if_missing` behavior preserved).
- Mount provisioning/dashboard paths read-only in `compose/compose.obs.yml` for Grafana.
- Set Grafana default home dashboard to `/etc/grafana/dashboards/agentic-activity-overview.json`.
- Extend promtail ingestion to include structured streams:
  - `gate-events` from `${AGENTIC_ROOT}/gate/logs/gate.jsonl`,
  - `gate-mcp-audit` from `${AGENTIC_ROOT}/gate/mcp/logs/audit.jsonl`,
  while keeping existing docker + egress streams.
- Add `tests/G2_obs_dashboard_provisioning.sh` to validate provisioning artifacts and Grafana API visibility.

## Consequences
- New installs get an actionable Grafana activity dashboard with no manual import.
- Tool/model activity is queryable by project labels when clients set `X-Agent-Project` (fallback remains `-`).
- Existing runtime customizations are preserved because provisioning files are only created when missing.
- Security posture is unchanged (loopback-only host binds, read-only config mounts, no docker.sock usage).
