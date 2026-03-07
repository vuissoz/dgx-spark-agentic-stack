# ADR-0061: Node runtime compatibility contract for `pi` CLI

## Status
Accepted

## Context
- In `rootless-dev`, running `pi` inside `optional-pi-mono` crashed with:
  - `SyntaxError: Invalid regular expression flags`
  - source path: `@mariozechner/pi-tui/dist/utils.js` using regexp flag `v`.
- Our `agent-cli-base` image installed Ubuntu `nodejs` (Node 18), while upstream `pi` sources declare a newer requirement (`engines.node >= 20.6.0`).
- This mismatch made `pi` unusable even when npm install succeeded.

## Decision
1. Upgrade `agent-cli-base` Node runtime baseline to NodeSource LTS (`AGENT_NODE_MAJOR=22` by default).
2. Enforce a minimum Node contract at image build time (`>=20.6.0`) to fail fast on drift.
3. Guard `pi` CLI installation in `install-agent-clis.sh`:
   - install only when Node runtime is `>=20.6.0`,
   - record `pi` as missing otherwise (or fail when `AGENT_CLI_INSTALL_MODE=required`).
4. Strengthen `K4_pi_mono` regression checks:
   - assert Node runtime version in container,
   - probe `pi` execution when binary is installed and reject known regex crash signature.

## Consequences
- `optional-pi-mono` no longer starts with a Node runtime incompatible with upstream `pi`.
- Compatibility drift is surfaced early in image build/test instead of at operator runtime.
- Existing best-effort offline behavior is preserved (missing `pi` binary is explicit and test warns).
