# ADR-0150 — Local n8n AI sandbox with Sysbox

## Status

Superseded by ADR-0151. Sysbox is no longer installed on the DGX host.

## Context

The self-hosted n8n AI Assistant requires a code sandbox. The generic n8n
Compose example uses a privileged Docker-in-Docker runner, while the project
forbids privileged containers and host `docker.sock` mounts. n8n also
publishes a Linux production path based on `sysbox-runc`, which runs the
nested Docker daemon without `privileged: true`.

The requested deployment must remain entirely local: model inference,
sandbox execution, and search all run in the stack.

## Decision

- Add the opt-in `optional-n8n-ai` profile.
- Run the official n8n sandbox API and DinD runner with
  `runtime: sysbox-runc`; fail closed when Sysbox is unavailable.
- Never mount the host Docker socket and never fall back to privileged mode.
- Bootstrap API/runner mTLS locally and persist its material below
  `${AGENTIC_ROOT}/optional/n8n/sandbox/tls`.
- Seed the sandbox image through a short-lived Skopeo service into an internal
  registry. Keep the runner, registry, API, and nested sandboxes on an
  `internal: true` network.
- Preconfigure n8n with local Ollama-compatible inference through
  `ollama-gate`, the local sandbox API, and local SearXNG.
- Generate four independent sandbox/search secrets under
  `${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox`.

The runner cannot use the ordinary `cap_drop: [ALL]` service baseline:
starting a nested daemon requires the container-level capability model
virtualized by Sysbox. The compensating controls are the dedicated Sysbox
runtime, no privileged flag, no host socket, no host port, internal-only
networking, bounded sandbox count/resources, and explicit doctor checks.

## Consequences

The host must install and register Sysbox separately; the repository does not
silently alter the Docker daemon. The profile cannot start until that
prerequisite is satisfied. Initial image seeding needs controlled registry
egress, while generated code has no direct egress path. TLS and API state are
included in the n8n runtime backup/rollback scope.
