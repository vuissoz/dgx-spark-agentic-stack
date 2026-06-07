# ADR-0130: Repo-e2e project-scoped instruction files per harness

## Status

Accepted

## Context

The known-local-tools manifest reduced ambiguity about which shell commands were
safe to use, but several baseline harnesses still behaved as if no project-level
instructions existed:

- they did not consistently treat the repository root as the only workspace,
- they sometimes stopped at inspection instead of implementing the fix,
- and they had no harness-specific reminder about how to use the local shell
  path instead of synthetic tool-call wrappers.

The top-level repository already has its own `AGENTS.md`, but the cloned
reference repository used by `repo-e2e` is intentionally minimal and does not
ship harness-specific instruction files.

## Decision

- During `repo-e2e` workspace preparation, inject ignored project-scoped
  instruction files into the cloned repository root.
- Always materialize:
  - `AGENTS.md`
  - `AGENT.md`
  - `SKILLS.md`
- Also materialize one harness-specific file according to the active mode:
  - `CODEX.md`, `CLAUDE.md`, `OPENCODE.md`, `KILOCODE.md`, `OPENHANDS.md`,
    `PI-MONO.md`, `GOOSE.md`, `VIBESTRAL.md`, `HERMES.md`, or `OPENCLAW.md`
- Add those injected files to `.git/info/exclude` so the repo-e2e publish
  contract still ends with a clean worktree.
- Update the generic repo-e2e prompt to tell each harness to read:
  - the generic project files,
  - its harness-specific file,
  - and the known local tools manifest.

## Consequences

- The cloned reference workspace now looks more like a real operator repository
  with durable repo-local instructions.
- Harness-specific guidance becomes explicit without mutating the seeded
  reference repository history.
- The injected instruction files remain local runtime scaffolding and do not
  interfere with the final git cleanliness/publish checks.
