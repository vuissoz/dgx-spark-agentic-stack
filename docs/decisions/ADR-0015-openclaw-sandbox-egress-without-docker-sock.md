# ADR-0015: OpenClaw sandbox egress pattern without docker socket mount

## Status
Accepted

## Context
Operator feedback highlighted a practical upstream OpenClaw pattern for sandbox isolation:
- default sandbox network disabled (`network=none`),
- optional egress through a dedicated proxy network,
- browser side ports derived from gateway port.

Upstream examples often rely on mounting `/var/run/docker.sock` into the gateway container to create sandbox containers.  
This repository has a non-negotiable guardrail: no `docker.sock` mount in containers.

## Decision
- Keep repository policy unchanged: no `docker.sock` mount for OpenClaw or any other service.
- Document a compliant pattern for upstream OpenClaw deployments:
  - sandbox defaults to `network=none`,
  - egress-enabled sessions use a dedicated network (`sbx_egress`) with proxy mediation,
  - policy is enforced at network/proxy layers, not only by proxy env vars.
- Add explicit browser caveat documentation:
  - loopback-derived browser ports (`18791`, `18792`) are not automatically reachable across containers,
  - do not broaden binds to `0.0.0.0` as a workaround.
- Publish operator examples in `examples/optional/` and guidance in `docs/security/openclaw-sandbox-egress.md`.

## Consequences
- Security posture remains aligned with CDC constraints (`no docker.sock`, loopback-only exposure).
- Operators still get a concrete path to fail-closed sandbox egress controls.
- Upstream OpenClaw integrations requiring dynamic container creation need a controlled host-side launcher/API rather than direct Docker socket access from containers.
