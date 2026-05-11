# ADR-0113 — `agentic-kilocode` as a first-class managed agent

## Context

The stack already ships persistent first-class agent surfaces for `claude`, `codex`, `opencode`, `vibestral`, and `hermes`. A new Kilocode surface must integrate with the same operational contract:

- hardened loopback-only Compose deployment,
- persistent tmux-backed session via `./agent kilocode`,
- dedicated `${AGENTIC_ROOT}/kilocode/{state,logs,workspaces}`,
- onboarding, doctor, and git-forge bootstrap parity,
- default routing through `ollama-gate`.

Kilocode 1.0 currently documents:

- CLI install via `npm install -g @kilocode/cli`,
- executable name `kilo`,
- global config under `~/.config/kilo/opencode.json` or `opencode.jsonc`,
- OpenCode-compatible config semantics.

## Decision

Add `agentic-kilocode` as another baseline agent service, backed by the shared `agentic/agent-cli-base` image.

Implementation details:

- install `@kilocode/cli` in the shared image and expose the `kilo` executable through the standard wrapper path contract (`/etc/agentic/kilo-real-path`);
- create a dedicated `agentic-kilocode` service with the same hardening posture as other agent CLI services;
- manage the Kilocode runtime config at `/state/home/.config/kilo/opencode.json`;
- pin the managed provider to `ollama-gate` using the OpenAI-compatible `/v1` endpoint and `model=ollama/<default-model>`;
- extend `agent`, onboarding, filesystem bootstrap, doctor checks, and git-forge bootstrap to treat `kilocode` like other first-class agents.

## Consequences

- Operators get `./agent kilocode <project>` with the same lifecycle semantics as the other baseline agents.
- Kilocode persists state independently from OpenCode even though it reuses OpenCode-compatible config semantics.
- The integration remains deterministic for local Ollama-first deployments without introducing new public binds or `docker.sock` exposure.
