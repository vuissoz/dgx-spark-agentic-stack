# ADR-0017: Step K1 OpenClaw runtime with dedicated sandbox and signed webhooks

## Status
Accepted

## Context
Step K1 requires OpenClaw to remain optional but enforce the same baseline controls as core services, with additional safeguards:
- explicit sandbox separation for tool execution,
- request/audit correlation,
- webhook ingress limited to loopback and protected by authentication plus signature,
- no `docker.sock` mount.

The previous optional OpenClaw implementation only covered token auth, DM allowlist, and basic audit logs.

## Decision
- Add a dedicated service pair under the same optional profile:
  - `optional-openclaw` (control API),
  - `optional-openclaw-sandbox` (tool runtime).
- Keep both services hardened (`read_only`, `cap_drop: ALL`, `no-new-privileges`, non-root) and on internal Docker networking.
- Route tool execution through an explicit OpenClaw -> sandbox HTTP channel with:
  - pre-execution sandbox reachability check,
  - timeout-bound call,
  - correlated `request_id` in both OpenClaw and sandbox audit entries.
- Enforce dual webhook controls on OpenClaw:
  - bearer token auth,
  - HMAC signature verification (`X-Webhook-Timestamp`, `X-Webhook-Signature`) using runtime secret file.
- Expose webhook ingress only on host loopback (`127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`), never on public interfaces.
- Extend runtime init and doctor/tests to include:
  - OpenClaw webhook secret and tool allowlist materialization,
  - sandbox service security/proxy/no-docker-sock checks,
  - signed webhook accept/reject scenarios,
  - direct egress bypass checks without proxy env.

## Consequences
- K1 control objectives are verifiable in automated tests (`tests/K1_openclaw.sh`).
- Operators must manage an additional runtime secret: `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`.
- OpenClaw health depends on sandbox reachability by design (fail-closed behavior for tool execution path).
