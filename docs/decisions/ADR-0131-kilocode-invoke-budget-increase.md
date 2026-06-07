# ADR-0131: Larger repo-e2e invoke budget for Kilocode

## Status

Accepted

## Context

`kilocode` already had a repo-e2e salvage path for `invoke failed exit=124`,
but repeated runs still showed the same pattern:

- the agent often edits the repository correctly,
- but its non-interactive session takes longer to terminate cleanly than the
  other baseline harnesses,
- so the shared invoke timeout is hit before the orchestrator can observe a
  normal completion.

That creates noisy false negatives even when the workspace is otherwise valid.

## Decision

- Keep the existing global `--invoke-timeout` flag for the common case.
- Apply a Kilocode-specific effective invoke timeout in `repo-e2e`:
  - requested timeout stays visible in artifacts,
  - `kilocode` gets a minimum effective invoke budget of `1800` seconds.
- Record both values in repo-e2e plan/result artifacts:
  - `invoke_timeout_requested`
  - `invoke_timeout_effective`

## Consequences

- `kilocode` gets more time to complete its native non-interactive session
  before being classified as `exit=124`.
- Other harnesses keep the current invoke budget and failure profile.
- Timeout behavior stays auditable in the generated validation artifacts.
