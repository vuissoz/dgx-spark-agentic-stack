# Managed OpenClaw default skills

The stack ships a safe, local baseline through the `stack-default-skills` plugin (version `1.1.0`). It is copied from the repository into `${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/.openclaw/skills` by `deployments/core/init_runtime.sh`.

Each entry is a repo-maintained prompt package under `examples/optional/openclaw-default-skills-plugin/skills/`, pinned by the Git commit and release artifact. The baseline does not install from ClawHub, does not require secrets, and grants no new egress or executable permissions. A skill requiring an external provider remains opt-in and needs its own pinned provenance, secret policy, and egress decision.

The current catalog is:

- `aclawdemy`, `agent-browser`, `agent-security-watcher`, `architecture-reviewer`, `capability-evolver`, `capability-evolver-plus-plus`, `citation-auditor`, `clawbot-filesystem`, `clawdbot-logs`, `clawflows`, `clawhub`, `code-reviewer`.
- `ddg-search`, `decision-assistant`, `dependency-auditor`, `documentation-builder`, `find-people`, `find-skills`, `foundry`, `github-repo-manager`, `githup`, `gog`, `google-search`, `grant-writer`, `humanizer`.
- `knowledge-base-rag`, `knowledge-curator`, `knowledge-gap-detector`, `literature-review`, `literature-scout`, `meeting-synthesizer`, `memory-system-v2`, `mission-control`, `nano-pdf`, `notebooklm-skill`, `openai-whisper`, `paper-reviewer`, `perplexity`, `pre-mortem`, `proactive-agent`.
- `red-team`, `self-improving`, `summarize`, `test-engineer`, `workspace-cartographer`.

Verify an existing stack:

```bash
./agent doctor
docker exec "$(docker ps -q --filter name=openclaw)" openclaw skills list --json
```

For a disposable rootless verification, run:

```bash
AGENTIC_PROFILE=rootless-dev AGENTIC_ROOT="$PWD/.runtime/openclaw-skills-check" \
  AGENTIC_COMPOSE_PROJECT=agentic-openclaw-skills-check \
  bash tests/K16_openclaw_default_skills_catalog.sh
```

Tear down that temporary project with the same three environment variables and `./agent down core`; do not remove a production runtime root for this check.
