# Plan - dgx-spark-agentic-stack-l7w

## Objective
Add a single user-friendly command that runs the first-start sequence end-to-end:
`source .runtime/env.generated.sh`, `agent profile`, `init_fs`, `agent up core`, `agent up agents,ui,obs,rag`, `agent doctor`.

## Scope
- Add a new `agent` subcommand for one-shot first startup.
- Keep behavior deterministic and actionable in both `strict-prod` and `rootless-dev`.
- Ensure GitHub reachability is explicitly covered for every agent container (`github.com` DNS + egress path).
- Make tmux persistence explicit when users connect to agent shells.
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

5. GitHub connectivity baseline for each agent:
- update plan/docs so onboarding allowlist includes required GitHub domains,
- add validation guidance for each agent (`getent hosts github.com`, optional SSH reachability check).

6. Add a connection notice for persistent tmux shells:
- display a short message when `agent <tool>` prepares/attaches to explain persistent session behavior,
- mention detaching shortcut (`Ctrl-b d`) so users do not confuse detach with stop.

7. Validation and delivery:
- run targeted tests,
- commit, `bd sync`, and push.
