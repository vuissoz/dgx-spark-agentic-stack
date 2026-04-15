# DGX Spark Agentic Stack

Turn a DGX Spark into a local-first agent platform: multiple coding agents, shared local models, hardened containers, controlled egress, rollbackable releases, and one operator entrypoint: `./agent`.

Current repo reality: the day-to-day green path is `rootless-dev`. `strict-prod` remains the production-like validation and CDC acceptance profile.

This repository is built for people who want serious agent infrastructure on a single machine without turning that machine into an accidental public service.

## Why This Exists

- Run agent tools locally with loopback-only host exposure.
- Centralize model access through `ollama-gate`.
- Keep a reasonable security baseline: `read_only`, `cap_drop: ALL`, `no-new-privileges`, controlled egress.
- Operate the stack with one wrapper: deploy, inspect, update, rollback, and diagnose through `./agent`.

## What You Get

- Core model/runtime services: Ollama, `ollama-gate`, OpenClaw, DNS, egress proxy
- Agent containers: Claude, Codex, OpenCode, Vibestral, Hermes
- UIs: Forgejo, OpenWebUI, OpenHands, ComfyUI
- Optional observability and RAG stacks
- Release snapshots with deterministic rollback support

## Fast Start

Forgejo is part of the baseline UI stack: `./agent up ui`, `./agent up agents,ui,obs,rag`, and `./agent first-up` all converge it before `./agent doctor`.

`rootless-dev`:

```bash
export AGENTIC_PROFILE=rootless-dev
./deployments/bootstrap/init_fs.sh
./agent first-up
./agent doctor
```

`strict-prod`:

```bash
export AGENTIC_PROFILE=strict-prod
sudo ./deployments/bootstrap/init_fs.sh
sudo -E ./agent first-up
sudo ./agent doctor
```

Key day-2 commands:

```bash
./agent profile
./agent ls
./agent logs openclaw
./agent update
./agent rollback all <release_id>
```

## Read Next

- Detailed English reference: [README.en.md](README.en.md)
- Detailed French reference: [README.fr.md](README.fr.md)
- First-time setup: [docs/runbooks/first-time-setup.md](docs/runbooks/first-time-setup.md)
- Runbook index: [docs/runbooks/introduction.md](docs/runbooks/introduction.md)
- OpenClaw onboarding in this stack: [docs/runbooks/openclaw-onboarding-rootless-dev.md](docs/runbooks/openclaw-onboarding-rootless-dev.md)
- Security notes: [docs/security](docs/security)
- Architecture decisions: [docs/decisions](docs/decisions)

## Positioning

This is not a toy demo and not a generic “AI starter kit”.

It is an opinionated operator stack for running agentic services on DGX Spark with:
- local-first access,
- explicit operational controls,
- traceable updates,
- rollback as a built-in workflow,
- security constraints that stay visible in the implementation.

## License

Licensed under Apache 2.0. See [LICENSE](LICENSE).
Copyright 2026 Pierre-André Vuissoz.
