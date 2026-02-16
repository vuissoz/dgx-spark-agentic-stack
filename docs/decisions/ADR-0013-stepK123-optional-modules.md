# ADR-0013: Step K1-K3 optional risky modules

## Status
Accepted

## Context
Step K requires optional risky modules to stay disabled by default and to be activatable only with explicit need/success criteria while keeping baseline controls (loopback-only binds, no docker.sock, audit logs, proxy settings, and doctor gating).

## Decision
- Keep `compose/compose.optional.yml` profile-driven with:
  - `optional-sentinel` for K0 gating,
  - `optional-openclaw` and `optional-mcp-catalog` (local minimal control-plane services),
  - `optional-pi-mono` (optional tmux-based CLI agent runtime),
  - `optional-goose` (optional Goose CLI runtime based on `ghcr.io/block/goose:latest`),
  - `optional-portainer` (local-only UI, no docker.sock mount).
- Add `deployments/optional/init_runtime.sh` to provision runtime directories, allowlist templates, and request files under `/srv/agentic/deployments/optional/*.request`.
- Extend `agent up optional`:
  - run `agent doctor` gate unless `AGENTIC_SKIP_OPTIONAL_GATING=1`,
  - read `AGENTIC_OPTIONAL_MODULES` and only enable matching Compose profiles,
  - require request files with non-empty `need=` and `success=` fields,
  - require runtime secrets for `openclaw` and `mcp`,
  - append activation records to `/srv/agentic/deployments/changes.log`.
- Extend doctor checks for optional modules:
  - security baseline, proxy env for openclaw/mcp/pi-mono/goose,
  - explicit `docker.sock` mount absence,
  - loopback-only bind for optional portainer.
- Add tests `K1_openclaw.sh`, `K2_mcp.sh`, and `K3_portainer.sh`.

## Consequences
- Optional risky modules remain opt-in and gated by baseline compliance.
- Operators must provide explicit activation intent before deployment.
- Portainer remains intentionally detached from Docker socket to preserve the repo security baseline.
