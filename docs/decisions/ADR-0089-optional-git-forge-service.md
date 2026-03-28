# ADR-0089: Optional Internal Git Forge for Cross-Agent Collaboration

## Status
Proposed

## Context

Issue `dgx-spark-agentic-stack-zu7n` asks for a stack-managed Git server so the operator and all agent surfaces can collaborate on shared repositories inside the DGX Spark stack itself.

The requirement is broader than "run a Git web UI":

- repositories and the forge database must be persistent;
- the web interface must be reachable from the host side, but only through loopback;
- the operator must have a system manager/admin role;
- named accounts must exist for `openclaw`, `openhands`, `comfyui`, `claude`, `codex`, `opencode`, `vibestral`, `pi-mono`, and `goose`;
- those accounts must be usable by the agent containers for `git clone`, `fetch`, `pull`, and `push`;
- secrets must stay outside git and remain compatible with strict rollback expectations.

The existing stack already enforces loopback-only host exposure, release traceability, persistent runtime roots under `AGENTIC_ROOT`, and "no docker.sock" for services. The Git feature must fit that model instead of creating a parallel operational path.

## Decision

We plan the Git service as an optional module backed by a Forgejo-class forge:

- compose profile: `optional-git-forge`;
- service name target: `optional-forgejo`;
- host exposure: `127.0.0.1:${GIT_FORGE_HOST_PORT:-13000}` only;
- internal access for agents: private Docker network DNS/service name, no public bind;
- persistence root: `${AGENTIC_ROOT}/optional/git/`.

The runtime contract for the forge is:

- `${AGENTIC_ROOT}/optional/git/config`
- `${AGENTIC_ROOT}/optional/git/state`
- `${AGENTIC_ROOT}/optional/git/logs`
- `${AGENTIC_ROOT}/optional/git/db`
- `${AGENTIC_ROOT}/optional/git/repositories`
- `${AGENTIC_ROOT}/optional/git/bootstrap`

Authentication defaults to internal HTTPS plus file-backed credentials or PATs stored outside git. SSH for the forge is off by default because it adds additional host exposure, key lifecycle, and policy surface. It can be introduced later only if a documented requirement justifies it.

Bootstrap requirements are explicit:

- one operator account named `system-manager` with admin/system-manager privileges;
- one account per agent surface: `openclaw`, `openhands`, `comfyui`, `claude`, `codex`, `opencode`, `vibestral`, `pi-mono`, `goose`;
- idempotent provisioning so `agent update` can reconcile rather than duplicate users;
- credentials written to root-only secret files or injected env, never committed.

## Consequences

- `PLAN.md` now treats the forge as optional module `K6` with dedicated acceptance tests.
- `agent doctor` will need forge-specific checks when the profile is enabled: loopback bind, hardening, healthcheck, expected accounts, and persistence path validation.
- `agent update` and `agent rollback` will need a forge-aware snapshot/reconciliation path because repositories and database state must survive updates and remain restorable.
- Operator documentation must cover account lifecycle, repo creation, cross-agent sharing, backup/restore, and credential rotation.

## Follow-up

- Implement issue `dgx-spark-agentic-stack-zu7n`.
- If SSH becomes necessary later, create a dedicated ADR for the transport/security tradeoff rather than enabling it implicitly.
