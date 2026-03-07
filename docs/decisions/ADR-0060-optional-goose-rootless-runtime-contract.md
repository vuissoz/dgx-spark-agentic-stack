# ADR-0060: `optional-goose` rootless runtime contract under read-only rootfs

## Status
Accepted

## Context
- `optional-goose` used `read_only: true` but only mounted `/home/goose/.config/goose` writable.
- Upstream Goose writes sessions/logs in `~/.local/share/goose` and `~/.local/state/goose` in addition to `~/.config/goose`.
- In that layout, Goose panics on `goose session list` with a read-only filesystem error.
- The optional module lacked dedicated test coverage and doctor assertions for Goose runtime writability.

## Decision
1. Align `optional-goose` to the same rootless-safe home pattern as other agent containers:
   - explicit `user: ${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}`,
   - `HOME=/state/home`,
   - XDG config/data/state paths under `/state/home`,
   - writable state volume mounted at `/state`.
2. Keep baseline hardening/proxy controls unchanged:
   - `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges:true`,
   - `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`,
   - no `docker.sock` mount.
3. Add Goose-specific compliance gates:
   - doctor checks for HOME/XDG/OLLAMA_HOST contract and writable Goose session/log directories,
   - new `tests/K5_goose.sh` integration test validating activation and Goose session persistence.
4. Keep backwards compatibility for prior Goose config:
   - migrate legacy `/state/config.yaml` to `/state/home/.config/goose/config.yaml` on startup when present.

## Consequences
- `optional-goose` is usable in `rootless-dev` with read-only rootfs enabled.
- Misconfigurations now fail fast in `agent doctor` and K-suite regression tests.
- Goose optional module behavior is documented and reproducible with the same runtime conventions as other agents.
