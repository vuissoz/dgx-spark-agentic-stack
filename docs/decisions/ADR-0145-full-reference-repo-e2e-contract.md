# ADR-0145: Full-reference repo-e2e contract

## Status

Accepted

## Context

The original repository E2E canary only exercised a single-file eight queens
task. The v2 acceptance campaign also needs a separately seeded, multi-file
reference repository without making the OpenClaw sandbox a general code
execution surface.

## Decision

- Seed and protect `agent-stack-full-e2e` alongside the canary, and record its
  distinct clone URLs in Forgejo bootstrap state.
- Make `agent repo-e2e --repo` select the repository, clone URLs, task file,
  sentinel, commit message, and OpenClaw solver as one scenario contract.
- Keep two narrow reviewed OpenClaw solvers: the existing
  `repo.eight_queens.solve` and `repo.normalize_identifier.solve`. Each only
  operates on its fixed file in `/workspace`, tests it, and pushes only
  `agent/openclaw` with the managed SSH key.
- Reconcile missing versioned solver allowlist entries into an existing runtime
  allowlist; do not delete operator-added entries.

## Consequences

- A Forgejo bootstrap test verifies both seeded repositories and their `main`
  branch protection.
- The full scenario is testable with the same runner and evidence layout as
  the canary while retaining a small, reviewable OpenClaw authority boundary.
