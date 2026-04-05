# ADR-0099: Opt-in reset of repo-e2e agent branches

## Status

Accepted

## Context

The repository-driven E2E scenario seeds a shared Forgejo repository
`eight-queens-agent-e2e` whose `main` branch must remain a problem-only baseline.
Agents solve the exercise on their reserved `agent/<tool>` branches and are
already responsible for `git pull`, code changes, tests, `git commit`, and
`git push`.

The failure mode was branch reuse across runs: once `agent/<tool>` had already
been solved, a later `./agent repo-e2e` could start from that solved branch and
no longer represent a true from-scratch run.

## Decision

`./agent repo-e2e` now accepts an explicit destructive flag:

- `--reset-agent-branches`

When present, the runner:

1. verifies that the stack-managed Forgejo reference repository `main` branch
   still matches the seeded problem baseline;
2. force-resets only the selected remote `agent/<tool>` branches to the exact
   `main` commit in Forgejo;
3. records the reset evidence in `_preflight/`;
4. verifies, after checkout and before agent invocation, that each prepared
   branch still contains the unresolved baseline and still fails
   `python3 -m pytest -q`.

Without the flag, remote branches are left untouched and the previous behavior
is preserved.

The runner still does not commit or push the solution on behalf of the agents.

## Consequences

- Operators can request a deterministic from-scratch run when needed.
- Destructive history rewrites stay opt-in and scoped to the managed reference
  repository only.
- The seeded `main` branch remains the single source of truth for the exercise
  baseline.
