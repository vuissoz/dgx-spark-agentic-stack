# ADR-0020: Retry service IP resolution before DOCKER-USER enforcement

## Status
Accepted

## Context
During `strict-prod` VM validation (`agent vm test --allow-no-gpu`), `agent up core` could fail intermittently while applying host `DOCKER-USER` rules:
- `cannot resolve IPs for 'egress-proxy' on agentic agentic-egress`

The failure happens in a short startup race where services are created and started, but network IP inspection is attempted before Docker reports stable attachments.

## Decision
- Add bounded retries in `deployments/net/apply_docker_user.sh` for service IP resolution:
  - `AGENTIC_SERVICE_IP_RESOLVE_ATTEMPTS` (default `20`)
  - `AGENTIC_SERVICE_IP_RESOLVE_SLEEP_SECONDS` (default `1`)
- Keep strict failure behavior if IPs are still unresolved after retry budget.

## Consequences
- `agent up core` is resilient to startup timing jitter without weakening egress policy requirements.
- Failure messages remain explicit and actionable when infrastructure is genuinely broken.
