# ADR-0097: Converge `git-forge` with the baseline stack before `doctor`

## Status

Accepted

## Context

`git-forge` is enabled through `AGENTIC_OPTIONAL_MODULES`, but several baseline services
(`openclaw`, `openhands`, `comfyui`, `claude`, `codex`, `opencode`, `vibestral`) rely on its
Git identity/bootstrap contract during `agent doctor`.

Keeping Forgejo only behind `agent up optional` created an invalid order:

1. baseline stack starts,
2. `agent doctor` runs and requires Git bootstrap,
3. `agent up optional` is still gated on a green `agent doctor`,
4. Forgejo bootstrap never converges in the nominal path.

## Decision

When `AGENTIC_OPTIONAL_MODULES` includes `git-forge`, `optional-forgejo` is now started and
bootstrapped as part of the baseline `agent up agents,ui,obs,rag` flow.

This also applies to `agent first-up`, because it already delegates baseline startup to that
command before invoking `agent doctor`.

`git-forge` remains optional from an operator point of view:

- it is still activated explicitly through `AGENTIC_OPTIONAL_MODULES`,
- it still uses the `optional-git-forge` Compose profile,
- it is still persisted under `${AGENTIC_ROOT}/optional/git/`.

The change is only about deployment order and convergence timing.

## Consequences

- `agent doctor` can validate the expected Git bootstrap immediately after baseline startup.
- Operators no longer need a separate pre-doctor `agent up optional` step just to satisfy
  Forgejo-backed Git checks.
- The generic `agent up optional` gate remains intact for other optional modules.
