# Runbook: Optional Risky Modules (Step K)

## Scope
Optional modules are disabled by default and are deployed only with explicit activation intent.

Supported modules:
- `openclaw`
- `mcp`
- `pi-mono`
- `goose`
- `portainer`

## Preconditions
1. Baseline stack is healthy: `./agent doctor` returns success.
2. Activation request file exists with non-empty `need=` and `success=` values:
   - `/srv/agentic/deployments/optional/openclaw.request`
   - `/srv/agentic/deployments/optional/mcp.request`
   - `/srv/agentic/deployments/optional/pi-mono.request`
   - `/srv/agentic/deployments/optional/goose.request`
   - `/srv/agentic/deployments/optional/portainer.request`
3. Runtime secrets are present for token-protected modules:
   - `/srv/agentic/secrets/runtime/openclaw.token`
   - `/srv/agentic/secrets/runtime/mcp.token`

## Activation
Example (single module):

```bash
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
```

Example (multiple modules):

```bash
AGENTIC_OPTIONAL_MODULES=mcp,pi-mono,goose,portainer ./agent up optional
```

Activation appends an audit entry in `/srv/agentic/deployments/changes.log`.

## Validation
Run:

```bash
./agent doctor
./agent test K
```

## Security Notes
- No optional module is exposed on `0.0.0.0`.
- `docker.sock` mounts are forbidden, including optional modules.
- Optional modules keep baseline hardening (`cap_drop: ALL`, `no-new-privileges`, read-only root filesystem where applicable).
