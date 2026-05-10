# ADR-0112: Clarify the remaining scope of agent unprivileged user namespaces

## Status

Accepted

## Context

Issue `dgx-spark-agentic-stack-7g8k` stayed open with an ambiguous scope:

- one interpretation was "managed agent containers are still broken until
  unprivileged user namespaces work natively inside them";
- another interpretation was "the runtime gap is already operationally covered
  by the existing fallbacks".

The current stack behavior is mixed:

- repository-style tasks already work inside managed agent containers;
- the managed `codex` wrapper detects blocked namespace sandboxing and falls
  back to `--dangerously-bypass-approvals-and-sandbox` inside the already
  constrained container runtime;
- this means user namespace support is not a release blocker for the current
  repo-e2e/operator workflow;
- but it is still a real runtime gap for any future feature that requires
  native unprivileged namespace sandboxing instead of the stack-level outer
  isolation.

## Decision

- Keep `dgx-spark-agentic-stack-7g8k` open, but narrow its meaning:
  it is now a runtime enhancement/hardening issue, not a baseline delivery
  blocker.
- Do not treat broad capability additions (`cap_add`, weaker confinement) as an
  automatic fix.
- Treat the current Codex fallback and existing container confinement as the
  accepted operational posture for the present stack contract.

## Consequences

- Backlog triage can distinguish between:
  - current operator-visible regressions,
  - future runtime-hardening improvements.
- Follow-up work on `7g8k` should prove a concrete remaining failure mode before
  changing the hardening profile of agent containers.
