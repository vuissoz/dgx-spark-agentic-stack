# ADR-0117: Kilocode invoke-timeout salvage in repo-e2e

## Status

Accepted

## Context

Kilocode could edit the target repository correctly during `repo-e2e` but still
hit the invoke timeout before it completed the full test/commit/push contract.

That produced a hard `invoke failed exit=124` classification even when the
workspace was already salvageable by the orchestrator.

## Decision

- Keep the normal invoke timeout classification for most agents.
- Add a Kilocode-specific salvage path in `repo-e2e`:
  - when invoke exits `124`,
  - run the standard orchestrator verification step,
  - then apply the adapter publish guard,
  - then verify the pushed branch contract.

## Consequences

- Kilocode no longer loses valid work solely because its non-interactive session
  timed out after editing.
- A timeout still fails if the workspace does not pass tests or cannot be
  published cleanly.
