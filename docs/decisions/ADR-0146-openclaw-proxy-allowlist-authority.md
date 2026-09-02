# ADR-0146: OpenClaw cannot promote proxy destination allowlists

## Status

Accepted

## Context

OpenClaw has durable approvals for its own DM targets and sandbox tools. Those
approvals may be promoted into the matching OpenClaw configuration artifacts.
The egress proxy allowlist controls a different trust boundary: it grants
network destinations to every container that can reach the controlled proxy.

## Decision

- Do not add an OpenClaw approval or promotion path for proxy/domain entries.
- Keep `${AGENTIC_ROOT}/proxy/allowlist.txt` administrator-managed, reviewed
  and fail-closed.
- Changes use the documented host edit plus `agent up core` reconciliation,
  release snapshotting, doctor checks and normal rollback; they are never
  inferred from a chat request, tool call or blocked egress attempt.
- OpenClaw approvals remain limited to the DM and tool allowlists under
  `${AGENTIC_ROOT}/openclaw/config/`.

## Consequences

- A compromised or over-permissive OpenClaw session cannot broaden stack-wide
  egress authority.
- Operators retain a clear audited change boundary for proxy destinations.
- Requests for a new external domain are an operational change, not a chat
  approval workflow.
