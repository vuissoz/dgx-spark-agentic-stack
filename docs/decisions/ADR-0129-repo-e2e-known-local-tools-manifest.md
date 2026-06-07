# ADR-0129: Repo-e2e known local tools manifest for baseline agent CLIs

## Status

Accepted

## Context

Recent `repo-e2e` runs showed a recurring failure pattern on the baseline agent
CLIs (`codex`, `claude`, `opencode`):

- the task itself is trivial and the local model often knows the solution,
- but the agent session still loses time probing the runtime,
- guesses alternate workspace paths,
- or emits malformed pseudo tool metadata instead of using the shell commands
  already available inside the container.

The stack already bootstraps local-provider defaults into `/state/bootstrap/`,
but it did not provide a compact machine-readable contract describing the known
local commands that repo-style tasks should prefer.

## Decision

- Generate two bootstrap artifacts in every baseline agent container:
  - `/state/bootstrap/known-local-tools.json`
  - `/state/bootstrap/known-local-tools.md`
- Populate them with:
  - the active shell contract (`/bin/sh`),
  - workspace and state roots,
  - a reviewed list of preferred repo-e2e commands (`pwd`, `ls`, `find`,
    `sed`, `cat`, `git`, `python3`, `pytest`) and their resolved paths.
- Install a small helper, `agent-known-tools`, that prints the markdown
  manifest directly from the container.
- Update the generic `repo-e2e` prompt to:
  - read the known-tools manifest first,
  - prefer direct shell commands from that manifest,
  - avoid invented tool schemas or pseudo tool tags,
  - avoid guessing alternate workspace paths.

## Consequences

- Repo-style tasks now start from an explicit local command contract instead of
  open-ended runtime discovery.
- The prompt is more specific without becoming agent-specific.
- Future regressions become testable through bootstrap/runtime contract checks.
