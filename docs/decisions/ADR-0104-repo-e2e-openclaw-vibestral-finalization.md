# ADR-0104: Repo-e2e OpenClaw and Vibestral finalization

## Status

Accepted

## Context

The repository-driven multi-agent E2E runner had two remaining live gaps in
rootless-dev:

- OpenClaw had no non-interactive repo-solving adapter.
- Vibestral could edit the target file but sometimes stopped before the required
  test, commit, and push contract.

Claude also needed to fail fast when no login state is mounted, otherwise the
runner could burn the full invocation timeout before producing an actionable
failure.

## Decision

- Add a narrow OpenClaw sandbox tool, `repo.eight_queens.solve`, to the reviewed
  default allowlist.
- The tool is not a general shell. It only accepts a workspace under
  `/workspace`, the reserved `agent/openclaw` branch, updates
  `src/eight_queens.py`, runs `python3 -m pytest -q`, commits the target file
  when needed, and pushes the current branch.
- The repo-e2e runner invokes OpenClaw through the live local
  `/v1/tools/execute` API with the file-backed OpenClaw token.
- Add a shared adapter publish guard for adapters with known stop-before-push
  behavior; Vibestral uses it after orchestrator verification passes.
- Add a Claude auth preflight that checks for a mounted Claude login marker
  before model warmup and checkout. Operators can opt into explicit env-only
  local-provider testing with `AGENTIC_REPO_E2E_CLAUDE_ALLOW_ENV_ONLY_AUTH=1`.

## Consequences

- OpenClaw participates in the live repo-e2e path without a fake shell fallback
  or a `docker.sock` mount.
- Vibestral runs become deterministic at the Git publication boundary while its
  edit and test output still remain captured separately.
- Missing Claude login becomes a short, classified invocation failure with
  `auth-preflight.*.log` artifacts.
