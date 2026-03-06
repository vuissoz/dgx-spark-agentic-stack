# ADR-0053: Automated Ollama Contract Drift Watch (Step 14)

## Status
Accepted

## Context
The stack depends on fast-moving upstream Ollama integration contracts:

- `ollama launch` behavior,
- integration setup pages (`codex`, `claude`, `opencode`, `openclaw`),
- API compatibility pages (OpenAI/Anthropic).

Without automated watch, contract drift can silently break onboarding defaults, agent bootstrap env, gateway compatibility assumptions, and tests.

The backlog issue `dgx-spark-agentic-stack-ygu` requires:

1. weekly scheduled watch,
2. explicit failure on contract drift,
3. automatic Beads issue creation/update with drift summary.

## Decision
1. Add a dedicated watcher script:
   - `scripts/ollama_drift_watch.sh`.
2. Use official source-of-truth pages from:
   - `raw.githubusercontent.com/ollama/ollama/main/docs/...`.
3. Validate both:
   - invariants (commands/env names/endpoints),
   - content hash drift versus local baseline snapshots.
4. Persist watch artifacts under:
   - `${AGENTIC_ROOT}/deployments/ollama-drift/`.
5. On drift:
   - exit with code `2`,
   - generate detailed report,
   - open/update Beads issue (default `dgx-spark-agentic-stack-ygu`) with deduplicated comment flow.
6. Add scheduling helper:
   - `scripts/install_ollama_drift_watch_schedule.sh`, exposed via
   - `agent ollama-drift schedule`.
   - backend priority: `systemd --user` timer, fallback to user cron.
7. Add regression test:
   - `tests/F10_ollama_drift_watch.sh` with deterministic local fixtures and schedule dry-run validation.

## Consequences
- Upstream contract drift becomes visible quickly and actionable.
- Operators in `rootless-dev` can install weekly watch without root.
- Drift reporting is traceable in runtime artifacts and Beads.
- Baseline refresh is explicit (`--ack-baseline`) and auditable, reducing accidental acceptance of contract changes.
