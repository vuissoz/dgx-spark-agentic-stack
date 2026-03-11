# ADR-0070: OpenClaw container CLI parity, operator dashboard, and provider relay runtime

## Status
Accepted (2026-03-11)

## Context

OpenClaw in this repository was already available as an optional API + sandbox runtime, but four operator gaps remained:

1. No container-native wizard parity for `openclaw onboard`, `openclaw configure`, and `openclaw agents add`.
2. No operator dashboard endpoint equivalent to upstream dashboard workflows.
3. No built-in provider relay path for external webhook ingestion with durable queue + retry/dead-letter.
4. No dedicated automated test coverage for the full CLI configuration path and relay edge cases.

Security and CDC constraints still apply:
- host exposure must stay loopback-only,
- no `docker.sock` mounts,
- hardened containers (`read_only`, `cap_drop: ALL`, `no-new-privileges`),
- persistent state under `${AGENTIC_ROOT}`,
- release/update/rollback traceability unchanged.

## Decision

1. Install the upstream OpenClaw CLI in the optional modules image via `https://openclaw.ai/install-cli.sh` and expose it as `openclaw` in-container.
2. Persist OpenClaw CLI state with `OPENCLAW_HOME=/state/cli/openclaw-home` and `OPENCLAW_CONFIG_PATH=/state/cli/openclaw-home/openclaw.json`, with operator workspaces under `/workspace` mapped to `${AGENTIC_ROOT}/optional/openclaw/{state,workspaces}`.
3. Add dashboard endpoints in OpenClaw runtime:
   - `GET /dashboard` (operator UI)
   - `GET /v1/dashboard/status` (runtime + relay queue status)
4. Add a dedicated relay service (`optional-openclaw-relay`) with:
   - signed provider ingestion: `POST /v1/providers/<provider>/webhook`
   - durable queue files (`pending`, `done`, `dead`)
   - retry/backoff and dead-letter flow
   - forwarding to local OpenClaw webhook endpoint (`/v1/webhooks/dm`)
5. Keep both dashboard and relay host publication loopback-only:
   - `127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`
   - `127.0.0.1:${OPENCLAW_RELAY_HOST_PORT:-18112}`
6. Extend doctor checks and optional runtime/bootstrap contracts for:
   - CLI availability in-container
   - writable `/workspace` mount
   - dashboard reachability
   - relay queue endpoint and config contract
7. Add dedicated regression test coverage in `tests/K6_openclaw_cli_dashboard_relay.sh`.

## Consequences

Positive:
- Operators can run OpenClaw setup flows directly inside the OpenClaw container with persistent artifacts.
- Dashboard posture is aligned with stack access model (SSH/Tailscale tunnel to loopback binds).
- Provider relay path is production-oriented (signed ingress, queue durability, retries, dead-letter, audit trail).
- Test and doctor coverage now validate these capabilities explicitly.

Trade-offs:
- Optional OpenClaw now includes an additional service (`optional-openclaw-relay`) and more runtime files/secrets.
- Relay operation adds queue lifecycle management responsibilities for operators.

## Validation

- `scripts/doctor.sh` checks dashboard, relay endpoint, loopback-only ports, CLI presence, and workspace mount contract.
- `tests/K6_openclaw_cli_dashboard_relay.sh` validates:
  - CLI wizard/config/agent flows and persistence,
  - actionable error path for invalid CLI configure input,
  - dashboard endpoints,
  - relay happy path, invalid signature rejection, duplicate idempotence, and dead-letter on downstream unavailability.
