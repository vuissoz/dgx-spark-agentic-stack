# ADR-0054: `optional-pi-mono` rootless stability and `agent` parity

## Status
Accepted

## Context
- In `rootless-dev`, `optional-pi-mono` was restarting in a loop because `HOME` defaulted to `/home/agent` (not writable for runtime UID/GID with read-only rootfs constraints).
- `pi-mono` was documented as a tmux-based agent runtime, but `./agent` did not expose a first-class `agent pi-mono <project>` workflow like `claude/codex/opencode/vibestral`.

## Decision
1. Align `optional-pi-mono` runtime env with baseline agents:
   - `AGENT_HOME=/state/home`, `HOME=/state/home`, XDG dirs under `/state/home`.
2. Align `optional-pi-mono` MCP/gate integration with baseline agents:
   - `GATE_MCP_URL`, `GATE_MCP_AUTH_TOKEN_FILE`, read-only mount of `${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token`.
   - Optional module prereqs now require this shared token file.
3. Extend `./agent` tool surface for parity:
   - add `pi-mono` to supported tool commands (`agent pi-mono`, `agent ls`, `agent stop`, `agent logs`).
4. Install upstream `pi` CLI (`@mariozechner/pi-coding-agent`) in `agent-cli-base` with the same wrapper/traceability model as other CLIs.
5. Strengthen compliance/testing:
   - doctor checks for `optional-pi-mono` HOME/mount/gate expectations,
   - add `K4_pi_mono.sh` regression test,
   - extend CLI/image tests to include `pi`.

## Consequences
- `optional-pi-mono` starts reliably in `rootless-dev` and remains health-checked.
- `pi-mono` is operable through the same `agent` tmux workflow as other agent services.
- Optional activation now explicitly depends on the shared gate token contract.
