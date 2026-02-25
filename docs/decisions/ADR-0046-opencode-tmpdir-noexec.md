# ADR-0046: OpenCode runtime temp dir on noexec /tmp

## Status
Accepted

## Context
Agent containers keep `/tmp` mounted as `tmpfs` with `noexec` for hardening.
OpenCode CLI (`opencode-ai`) loads a native TUI shared library from its temp directory at runtime.
With `TMPDIR` defaulting to `/tmp`, startup can fail after migration with:
- `Failed to initialize OpenTUI render library`
- `failed to map segment from shared object rejection`

## Decision
- Keep `/tmp` hardened (`noexec`) in compose.
- Set `TMPDIR=/state/tmp` for `agentic-opencode` in `compose/compose.agents.yml`.
- Update `deployments/images/agent-cli-base/entrypoint.sh` to create and chmod `TMPDIR` (`0700`) when provided.

## Consequences
- `opencode` starts reliably in hardened containers without manual `export TMPDIR=...`.
- Change scope is limited to `agentic-opencode`; other agents keep existing behavior.
- Security baseline remains intact for `/tmp` mount options.
