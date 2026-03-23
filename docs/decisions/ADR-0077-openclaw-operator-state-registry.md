# ADR-0077: OpenClaw operator state registry for sessions and sandboxes

## Status

Accepted

## Context

`openclaw-sandbox` already persisted a technical execution-plane registry in `${AGENTIC_ROOT}/openclaw/sandbox/state/session-sandboxes.json`.

That file is sufficient for lease/reuse/TTL mechanics, but it is too low-level for operator workflows tracked in `dgx-spark-agentic-stack-oop`:
- `agent ls` only exposed a raw sandbox count,
- `agent doctor` could only validate the presence of the execution registry,
- future OpenClaw workflows had no first-class local state contract for session-level visibility.

The target remains intentionally simpler than NemoClaw:
- no secrets in registry data,
- no Docker-per-session orchestration,
- keep the existing loopback-only and no-`docker.sock` constraints.

## Decision

Keep the existing technical registry unchanged and add a second, versioned operator registry:

- path: `${AGENTIC_ROOT}/openclaw/sandbox/state/openclaw-state-registry.v1.json`
- owner: `openclaw-sandbox`
- readers: `agent ls`, `agent doctor`, future OpenClaw operator workflows

Minimum persisted operator fields:
- top-level: `current_session_id`, `default_session_id`, `default_model`, `provider`, `policy_set`
- per session: `current`, `default`, `model`, `provider`, `policy_set`, `created_at`, `workspace`, `last_health`, `expires_at`
- per sandbox: `current`, `default`, `model`, `provider`, `policy_set`, `created_at`, `workspace`, `last_health`, `expires_at`

Runtime behavior:
- every lease or tool execution refreshes the operator registry,
- TTL expiration removes active sandboxes from the operator registry and appends to `recent_expired`,
- session entries remain persistent and are marked inactive/expired when their last sandbox expires.

## Consequences

- `agent ls` can expose an operator-friendly summary (`sandboxes`, `sessions`, current/default session, provider, default model).
- `agent doctor` can validate schema, coherence with the technical registry, and absence of leaked secrets.
- OpenClaw has an explicit, versioned local state contract without coupling operator tooling to ad hoc runtime introspection.
