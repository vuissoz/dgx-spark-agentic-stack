# Plan - dgx-spark-agentic-stack-l7w

## Objective
Add a single user-friendly command that runs the first-start sequence end-to-end:
`source .runtime/env.generated.sh`, `agent profile`, `init_fs`, `agent up core`, `agent up agents,ui,obs,rag`, `agent doctor`.

## Scope
- Add a new `agent` subcommand for one-shot first startup.
- Keep behavior deterministic and actionable in both `strict-prod` and `rootless-dev`.
- Update first-time setup documentation.
- Add a focused CLI regression test.

## Steps
1. Add `agent first-up` command:
- auto-load onboarding env file when present,
- run sequence steps in strict order with clear step logging,
- support a safe `--dry-run` mode for testability.

2. Add failure guidance:
- on failure, stop immediately with non-zero exit,
- in `strict-prod` non-root context, print explicit sudo rerun hint.

3. Update docs:
- `docs/runbooks/first-time-setup.md` with one-command path.

4. Add test:
- add CLI test covering `first-up --dry-run` flow and env auto-load behavior.

5. Validation and delivery:
- run targeted tests,
- commit, `bd sync`, and push.
