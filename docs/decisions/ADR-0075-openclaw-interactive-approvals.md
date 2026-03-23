# ADR-0075: OpenClaw interactive approvals queue for blocked egress intents

## Status

Accepted - 2026-03-23

## Context

`dgx-spark-agentic-stack-e0q` extends the current OpenClaw baseline:
- static allowlists remain the first safety barrier,
- unknown `dm` targets or `tool` executions should not be silently dropped,
- operators need a durable queue and a host-side workflow to approve, deny, or promote requests without exposing the stack or weakening proxy rules.

The repository already enforces:
- loopback-only host exposure,
- no `docker.sock`,
- proxy/DOCKER-USER fail-closed posture,
- OpenClaw state under `${AGENTIC_ROOT}/openclaw/...`.

The missing piece is an explicit approval loop between "blocked by policy" and "manually edit files then retry".

## Decision

OpenClaw now keeps a durable approvals queue under `${AGENTIC_ROOT}/openclaw/state/approvals/` with four states:
- `pending`
- `approved`
- `denied`
- `expired`

Each record is keyed by the blocked intent (`kind` + `value`) and stores only non-secret metadata:
- request ids,
- session ids,
- model ids,
- source (`api`, `webhook`, `sandbox`),
- timestamps,
- counts.

No message body, secret, token, or raw tool arguments are persisted in that queue.

The operator workflow is implemented as:
- `agent openclaw approvals list`
- `agent openclaw approvals approve <id> --scope session|global ...`
- `agent openclaw approvals deny <id> --scope session|global ...`
- `agent openclaw approvals promote <id>`

Scope rules:
- `session`: temporary approval/denial bound to one `session_id`
- `global`: temporary approval/denial for all sessions
- `persistent`: produced only by `promote`, after appending the explicit value to the stack-managed allowlist artifact

Promotion targets are explicit and traceable:
- `dm_target` -> `${AGENTIC_ROOT}/openclaw/config/dm_allowlist.txt`
- `tool` -> `${AGENTIC_ROOT}/openclaw/config/tool_allowlist.txt`

Both `openclaw` and `openclaw-sandbox` reload their relevant allowlists dynamically so a persistent promotion becomes effective without a container restart.

## Consequences

- Unknown OpenClaw egress intents are still blocked by default, but they become visible and actionable.
- Session-scoped decisions do not leak outside the chosen session.
- Persistent promotions modify a versionable config artifact instead of creating hidden runtime state.
- Audit trail now includes `openclaw-approvals` events for enqueue/approve/deny/promote/expire.
- The proxy/domain allowlist remains fail-closed and non-interactive in this iteration; interactive approvals do not mutate Squid/domain policy.
