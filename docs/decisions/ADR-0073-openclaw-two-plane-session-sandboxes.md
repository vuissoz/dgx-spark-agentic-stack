# ADR-0073: OpenClaw two-plane runtime with session-scoped sandboxes

## Status
Accepted

## Context

The stack already had a durable OpenClaw control-plane:
- `openclaw`,
- `openclaw-gateway`,
- `openclaw-relay`.

But tool execution still relied on one long-lived shared `openclaw-sandbox` service.
That meant all OpenClaw tool runs shared the same execution boundary, which did not match the follow-up requirement tracked in `dgx-spark-agentic-stack-4xu`:
- keep the control-plane always on,
- isolate the execution-plane per sub-agent/session,
- reuse the same sandbox for the lifetime of a session,
- then expire it deterministically.

The repository guardrails still apply:
- no `docker.sock` in containers,
- no public host binds,
- no weaker gateway auth model.

## Decision

- Keep the control-plane services unchanged from an operator perspective:
  - `openclaw`,
  - `openclaw-gateway`,
  - `openclaw-relay`.
- Evolve `openclaw-sandbox` into an execution-plane orchestrator rather than a single shared tool runtime.
- Scope execution sandboxes by the pair `session_id + model`.
  - Same `session_id + model` reuses the same sandbox lease.
  - A model change inside the same session allocates a distinct sandbox.
  - A different session allocates a distinct sandbox.
- Persist the execution-plane registry under `${AGENTIC_ROOT}/openclaw/sandbox/state/session-sandboxes.json`.
- Persist dedicated sandbox workspaces under `${AGENTIC_ROOT}/openclaw/sandbox/workspaces/`.
- Expire inactive sandboxes on a TTL (`OPENCLAW_SANDBOX_SESSION_TTL_SEC`) with a reaper loop.
- Expose execution-plane visibility through:
  - `GET /v1/sandboxes/status` on `openclaw-sandbox`,
  - `GET /v1/dashboard/status` on `openclaw`,
  - `./agent ls` runtime summary (`sandboxes=<n>`),
  - `./agent doctor` validation of registry/mount/status endpoint.

## Consequences

- The stack now has a clearer control-plane / execution-plane split without relaxing security guardrails.
- OpenClaw tool execution is no longer globally shared across unrelated sessions/models.
- Session sandbox cleanup is deterministic and observable.
- This is intentionally not a dynamic Docker-per-session design; that would require a controlled host launcher/API and is out of scope for the current repository guardrails.
