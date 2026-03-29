# ADR-0094: OpenClaw TCP forwarder Prometheus metrics

## Context

`openclaw-gateway` publishes the upstream OpenClaw Web UI and WebSocket gateway through a tiny in-container TCP forwarder so the host only exposes loopback `127.0.0.1:${OPENCLAW_GATEWAY_HOST_PORT:-18789}`.

That forwarder had no native observability:
- no Prometheus endpoint,
- no direct counters for accepted connections or target-connect failures,
- no byte counters to distinguish traffic directions,
- no first-run Grafana signal for operators diagnosing gateway reachability.

The follow-up issue `dgx-spark-agentic-stack-wlx` requires native Prometheus metrics for these forwarders, integrated into the existing observability stack and validated by `agent doctor`.

## Decision

Implement native metrics in `deployments/optional/tcp_forward.py` and wire them into the stack as follows:

1. The TCP forwarder now exposes an internal HTTP endpoint with:
   - `/metrics` in Prometheus text format,
   - `/healthz` for a minimal liveness probe.
2. Export the following metric families:
   - `agentic_tcp_forwarder_info`
   - `agentic_tcp_forwarder_uptime_seconds`
   - `agentic_tcp_forwarder_connections_total{result=...}`
   - `agentic_tcp_forwarder_active_connections`
   - `agentic_tcp_forwarder_bytes_total{direction=...}`
3. Enable this endpoint for `openclaw-gateway` on internal-only `openclaw-gateway:9114`.
   - It is not host-published.
   - It remains reachable from Prometheus over the private Docker network.
4. Extend the managed Prometheus config with job `openclaw-tcp-forwarders`.
5. Extend the managed Grafana overview dashboard with dedicated health/traffic panels for the OpenClaw forwarder.
6. Extend `agent doctor` to validate:
   - the gateway metrics env contract,
   - direct metrics endpoint availability,
   - healthy Prometheus scraping when `prometheus` is running.
7. Add regression coverage in OpenClaw and observability tests.

## Consequences

Positive:
- Operators get direct visibility into OpenClaw gateway forwarding health and throughput.
- Prometheus/Grafana can distinguish gateway forwarder failures from upstream OpenClaw UI failures.
- The metrics path stays internal-only and keeps the host exposure contract unchanged.

Trade-offs:
- `openclaw-gateway` now runs one additional internal HTTP listener on `9114`.
- Existing runtimes need a managed migration for Prometheus config and dashboard artifacts; `deployments/obs/init_runtime.sh` performs that migration.
