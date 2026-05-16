# ADR-0115: Repo-E2E OpenClaw allowlist preflight and terminal progress

## Status

Accepted

## Context

The repository-driven E2E runner was already producing complete machine-readable
artifacts, but two operator gaps remained:

- a live `./agent repo-e2e` run gave almost no incremental terminal feedback
  until the final JSON summary was printed;
- OpenClaw could spend a full attempt only to fail late if the reviewed
  `repo.eight_queens.solve` tool had not been added to the effective tool
  allowlist.

These are operator-experience and fail-closed problems, not feature gaps.

## Decision

- Keep the final structured JSON result on `stdout` for automation.
- Stream timestamped progress events to `stderr` during planning, preflight, and
  each live attempt.
- Add an explicit OpenClaw preflight before live runs: if OpenClaw is selected,
  verify that `repo.eight_queens.solve` is present in the effective
  `OPENCLAW_TOOL_ALLOWLIST_FILE` and abort immediately if it is missing.

## Consequences

- Operators can watch `./agent repo-e2e` directly in a terminal without losing
  the existing JSON contract.
- Misconfigured OpenClaw policy now fails before model warmup, workspace
  preparation, or invocation timeouts.
- The preflight emits dedicated artifacts under `_preflight/` so allowlist
  failures remain auditable.
