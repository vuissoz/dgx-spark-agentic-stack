# ADR-0071: OpenClaw Upstream Gateway as Managed Optional Service (Loopback-Only)

## Status
Accepted

## Context

The optional OpenClaw module already exposed:
- stack API/dashboard on `127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`,
- relay ingress on `127.0.0.1:${OPENCLAW_RELAY_HOST_PORT:-18112}`.

Operators also need the upstream OpenClaw Web UI + Gateway WS on `127.0.0.1:18789` as part of normal `AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional` lifecycle, not as an ad-hoc container.

Constraints:
- keep loopback-only host exposure,
- keep security hardening (`read_only`, `cap_drop: ALL`, `no-new-privileges`),
- keep Docker network isolation (avoid host networking),
- keep token handling file-based (no automatic global secret export).

## Decision

Add a managed Compose service: `optional-openclaw-gateway` under profile `optional-openclaw`.

Implementation details:
- run upstream gateway in-container with:
  - `openclaw gateway run --allow-unconfigured --auth token --bind loopback --tailscale off --port 18789`,
  - token loaded from `/run/secrets/openclaw.token`.
- publish host loopback `127.0.0.1:${OPENCLAW_GATEWAY_HOST_PORT:-18789}` via an in-container TCP forwarder:
  - container proxy listens on `0.0.0.0:8114`,
  - forwards raw TCP to `127.0.0.1:18789` inside the same container,
  - host mapping remains loopback-only (`127.0.0.1:...:8114`).

This avoids `network_mode: host` while keeping upstream gateway bind mode as `loopback`.

## Consequences

Positive:
- Web UI (`http://127.0.0.1:18789`) and Gateway WS (`ws://127.0.0.1:18789`) are available in normal optional stack startup.
- `agent stop openclaw` and `agent forget openclaw` now include gateway service lifecycle.
- `agent doctor` verifies loopback bind, gateway port mapping, UI reachability, and WS token-auth health.

Trade-offs:
- one extra optional service/container,
- additional tiny runtime component (`tcp_forward.py`) to bridge loopback gateway without host network.
