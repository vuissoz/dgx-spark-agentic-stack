# ADR-0096 — Repo-driven multi-agent E2E V1

## Status
Accepted

## Context

The stack already exposes multiple agent containers and now embeds an internal
git forge. The missing piece is one central, non-interactive integration runner
that drives the same repository-hosted problem through the agent surfaces and
keeps full artefacts for later diagnosis.

The runner must stay compatible with the current rootless-dev workflow, where
some CLIs can be present while others are still installed in best-effort mode.

## Decision

- Bootstrap a dedicated reference repository in the internal forge:
  `eight-queens-agent-e2e`.
- Store the problem statement, Python target file, pytest contract, and branch
  policy directly in that repository.
- Protect `main` and reserve one `agent/<tool>` branch per managed agent.
- Add one repository-driven orchestrator:
  `deployments/optional/agent_repo_e2e.py`.
- Make the runner invocable through `./agent repo-e2e`.
- Use adapter-specific non-interactive execution where a stable contract exists:
  `codex`, `claude`, `opencode`, `vibe`, `pi`, `goose`, OpenHands via API,
  and OpenClaw via its controlled `/v1/tools/execute` sandbox API.
- Keep unsupported adapters explicit instead of silently falling back to a fake
  shell implementation. OpenClaw uses the narrow allowlisted
  `repo.eight_queens.solve` tool for this reference repository rather than a
  general shell runner.
- Persist per-agent stdout/stderr, git status/diff, verification logs, a
  unified `summary.json`, and a final `doctor.json`.

## Consequences

- The stack can now prepare one auditable repository contract for agent E2E
  checks without hard-coding the problem into the orchestrator prompt.
- Git-forge bootstrap is stricter: the shared team now converges to `write`
  access instead of `admin`, so branch protection on `main` remains meaningful.
- Follow-up work can focus on improving individual adapters without replacing
  the orchestration or artefact model.
