# Runbook: Optional Modules (Step K)

Optional modules are intentionally gated features. They are not part of the default baseline and are deployed only after explicit, auditable operator intent.

## Why Optional Modules Are Gated

These modules can increase operational or security exposure (more services, more persistence paths, and in some cases external integrations).  
For that reason, activation requires:
- a written request (`need` and success criteria),
- secret material when token-based auth is required,
- explicit opt-in through `AGENTIC_OPTIONAL_MODULES`,
- audit trail in deployment logs.

## Implemented Optional Modules

### `openclaw`
- Service: `optional-openclaw`
- Profile: `optional-openclaw`
- Purpose: token-protected optional API module for scoped workflows.
- Runtime data:
  - `${AGENTIC_ROOT}/optional/openclaw/config`
  - `${AGENTIC_ROOT}/optional/openclaw/state`
  - `${AGENTIC_ROOT}/optional/openclaw/logs`
- Secret required: `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`

### `mcp`
- Service: `optional-mcp-catalog`
- Profile: `optional-mcp`
- Purpose: token-protected MCP catalog module with tool allowlisting.
- Runtime data:
  - `${AGENTIC_ROOT}/optional/mcp/config`
  - `${AGENTIC_ROOT}/optional/mcp/state`
  - `${AGENTIC_ROOT}/optional/mcp/logs`
- Secret required: `${AGENTIC_ROOT}/secrets/runtime/mcp.token`

### `pi-mono`
- Service: `optional-pi-mono`
- Profile: `optional-pi-mono`
- Purpose: additional tmux-based CLI agent session, same operational model as baseline agents.
- Runtime data:
  - `${AGENTIC_ROOT}/optional/pi-mono/state`
  - `${AGENTIC_ROOT}/optional/pi-mono/logs`
  - `${AGENTIC_ROOT}/optional/pi-mono/workspaces`
- Secret required: no dedicated token file.

### `goose`
- Service: `optional-goose`
- Profile: `optional-goose`
- Purpose: optional Goose CLI workspace container for specific workflows.
- Runtime data:
  - `${AGENTIC_ROOT}/optional/goose/state`
  - `${AGENTIC_ROOT}/optional/goose/logs`
  - `${AGENTIC_ROOT}/optional/goose/workspaces`
- Secret required: no dedicated token file.

### `portainer`
- Service: `optional-portainer`
- Profile: `optional-portainer`
- Purpose: local-only Portainer UI for operational visibility.
- Runtime data:
  - `${AGENTIC_ROOT}/optional/portainer/data`
  - `${AGENTIC_ROOT}/optional/portainer/logs`
- Access: loopback host bind only (`127.0.0.1:${PORTAINER_HOST_PORT:-9001}`).

## Preconditions

1. Baseline stack is healthy:

```bash
./agent doctor
```

2. Activation request file exists and is complete for every module you enable:
- `${AGENTIC_ROOT}/deployments/optional/openclaw.request`
- `${AGENTIC_ROOT}/deployments/optional/mcp.request`
- `${AGENTIC_ROOT}/deployments/optional/pi-mono.request`
- `${AGENTIC_ROOT}/deployments/optional/goose.request`
- `${AGENTIC_ROOT}/deployments/optional/portainer.request`

Each request file must include non-empty:
- `need=<why this module is needed>`
- `success=<how success will be measured>`

3. Required runtime secrets exist with restrictive permissions (`600` or `640`):
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`
- `${AGENTIC_ROOT}/secrets/runtime/mcp.token`

## Activation

Single module:

```bash
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
```

Multiple modules:

```bash
AGENTIC_OPTIONAL_MODULES=mcp,pi-mono,goose,portainer ./agent up optional
```

What happens during activation:
- `agent` resolves requested module names to compose profiles,
- validates request files and required secrets,
- launches only selected optional services,
- appends an activation audit line in `${AGENTIC_ROOT}/deployments/changes.log`.

## Validation

Run:

```bash
./agent doctor
./agent test K
```

Expected result:
- optional services are healthy,
- baseline hardening rules remain true,
- no forbidden mounts or public binds are introduced.

## Security Notes

- Optional modules are still loopback-only where host ports are published.
- `docker.sock` mounts remain forbidden, including optional modules.
- Baseline hardening is preserved (`cap_drop: ALL`, `no-new-privileges`, read-only root filesystem where applicable).
- All optional service egress remains aligned with proxy-based policy when enabled in the baseline.
