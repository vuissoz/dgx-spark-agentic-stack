# Runbook: Optional Modules (Step K)

Optional modules are intentionally gated features. They are not part of the default baseline and are deployed only after explicit, auditable operator intent.

OpenClaw was promoted into the `core` stack by `ADR-0072` and is no longer controlled by `AGENTIC_OPTIONAL_MODULES`.

For a full beginner-friendly catalog of configuration variables, allowed values, storage, and secrets handling, see:
- `docs/runbooks/configuration-expliquee-debutants.md`
- `docs/runbooks/configuration-explained-beginners.en.md`

## Why Optional Modules Are Gated

These modules can increase operational or security exposure (more services, more persistence paths, and in some cases external integrations).  
For that reason, activation requires:
- a written request (`need` and success criteria),
- secret material when token-based auth is required,
- explicit opt-in through `AGENTIC_OPTIONAL_MODULES`,
- audit trail in deployment logs.

## Implemented Optional Modules

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
- Secret required: shared gate token `${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token`.
- Session access: `./agent pi-mono <project>`

### `goose`
- Service: `optional-goose`
- Profile: `optional-goose`
- Purpose: optional Goose CLI workspace container for specific workflows.
- Runtime contract:
  - explicit non-root user mapping (`AGENT_RUNTIME_UID:AGENT_RUNTIME_GID`),
  - `HOME=/state/home` with XDG dirs under `/state/home/.config`, `/state/home/.local/share`, `/state/home/.local/state`,
  - default provider wiring: `GOOSE_PROVIDER=ollama`, `OLLAMA_HOST=http://ollama-gate:11435`,
  - explicit Goose client window: `GOOSE_CONTEXT_LIMIT=${AGENTIC_GOOSE_CONTEXT_LIMIT:-${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-262144}}` (defaults to the selected model context window).
- Runtime data:
  - `${AGENTIC_ROOT}/optional/goose/state`
  - `${AGENTIC_ROOT}/optional/goose/logs`
  - `${AGENTIC_ROOT}/optional/goose/workspaces`
- Secret required: no dedicated token file.
- Session access: `./agent goose <project>`

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
- `${AGENTIC_ROOT}/deployments/optional/mcp.request`
- `${AGENTIC_ROOT}/deployments/optional/pi-mono.request`
- `${AGENTIC_ROOT}/deployments/optional/goose.request`
- `${AGENTIC_ROOT}/deployments/optional/portainer.request`

Each request file must include non-empty:
- `need=<why this module is needed>`
- `success=<how success will be measured>`

3. Required runtime secrets exist with restrictive permissions (`600` or `640`):
- `${AGENTIC_ROOT}/secrets/runtime/mcp.token`
- `${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token` (required by `pi-mono`)

### `git-forge`
- Tracking issue: `dgx-spark-agentic-stack-zu7n`
- Profile: `optional-git-forge`
- Service class: `optional-forgejo`
- Purpose: stack-managed internal Git hosting so the operator and all agent surfaces can share repositories through normal Git workflows.
- Runtime data:
  - `${AGENTIC_ROOT}/optional/git/config`
  - `${AGENTIC_ROOT}/optional/git/state`
  - `${AGENTIC_ROOT}/optional/git/bootstrap`
- Onboarding inputs:
  - `AGENTIC_OPTIONAL_MODULES+=git-forge`
  - `GIT_FORGE_HOST_PORT`
  - `GIT_FORGE_ADMIN_USER`
  - `GIT_FORGE_SHARED_NAMESPACE`
  - `GIT_FORGE_ENABLE_PUSH_CREATE`
- Activation path:
  - enable `git-forge` in `AGENTIC_OPTIONAL_MODULES`, then run `./agent up agents,ui,obs,rag` or `./agent first-up`
  - do not wait for a separate `./agent up optional`; doctor expects Forgejo bootstrap to exist before optional gating
- Agent bootstrap behavior:
  - preconfigure each agent container with its own forge identity and auth helper so first `git clone`/checkout works without manual credential entry
- Documentation: `docs/runbooks/git-forge-management.md`

## Activation

Single module:

```bash
AGENTIC_OPTIONAL_MODULES=mcp,pi-mono,goose,portainer ./agent up optional
```

What happens during activation:
- `agent` resolves requested module names to compose profiles,
- validates request files and required secrets,
- launches only selected optional services,
- exception: when `git-forge` is enabled, `optional-forgejo` is launched during the baseline `agents,ui,obs,rag` convergence so `doctor` sees a complete Git bootstrap,
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

Goose context verification (`optional-goose` enabled):

```bash
goose_cid="$(docker ps --filter "name=${AGENTIC_COMPOSE_PROJECT:-agentic}-optional-goose" --format '{{.ID}}' | head -n 1)"
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${goose_cid}" | grep '^GOOSE_CONTEXT_LIMIT='
goose_context_limit="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${goose_cid}" | sed -n 's/^GOOSE_CONTEXT_LIMIT=//p' | head -n 1)"
goose_context_display="$((goose_context_limit / 1000))k"
timeout 12 docker exec "${goose_cid}" sh -lc 'goose session -n context-check' 2>&1 | grep "/${goose_context_display}"
```

OpenClaw gateway port check (core OpenClaw exposes loopback `18789`; upstream variants may add `18791`/`18792`):

```bash
lsof -nP -iTCP -sTCP:LISTEN | egrep ':(18789|18791|18792|188[0-9]{2})'
ss -lntp | egrep ':(18789|18791|18792|188[0-9]{2})'
```

## Security Notes

- Optional modules are still loopback-only where host ports are published.
- `docker.sock` mounts remain forbidden, including optional modules.
- Baseline hardening is preserved (`cap_drop: ALL`, `no-new-privileges`, read-only root filesystem where applicable).
- All optional service egress remains aligned with proxy-based policy when enabled in the baseline.
