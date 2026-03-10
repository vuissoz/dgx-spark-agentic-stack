# Runbook: Optional Modules (Step K)

Optional modules are intentionally gated features. They are not part of the default baseline and are deployed only after explicit, auditable operator intent.

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

### `openclaw`
- Service: `optional-openclaw`
- Sandbox service: `optional-openclaw-sandbox`
- Profile: `optional-openclaw`
- Purpose: token-protected optional API module for scoped workflows.
- Current repo behavior:
  - internal API listener `:8111` on Docker network,
  - dedicated sandbox runtime `:8112` on Docker network,
  - versioned integration profile bootstrap:
    - `${AGENTIC_ROOT}/optional/openclaw/config/integration-profile.v1.json`
    - `${AGENTIC_ROOT}/optional/openclaw/config/integration-profile.current.json`,
  - signed webhook ingress on host loopback only (`127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`).
  - launch-inspired endpoint contract:
    - DM: `/v1/dm`, `/v1/dm/send`
    - webhook DM: `/v1/webhooks/dm`, `/v1/webhooks/channels/dm`
    - profile/capabilities: `/v1/profile`, `/v1/capabilities`
    - tool execution: `/v1/tools/execute`, `/v1/sandbox/tools/execute`
- Sandbox and egress hardening blueprint for upstream OpenClaw gateway deployments:
  - `docs/security/openclaw-sandbox-egress.md`
- If replaced by upstream OpenClaw gateway, default listeners are typically:
  - `18789` (gateway),
  - `18791` (`gateway.port + 2`, browser control),
  - `18792` (`gateway.port + 3`, relay),
  - `18800-18899` for local CDP when managed browser profiles are enabled.
- Runtime data:
  - `${AGENTIC_ROOT}/optional/openclaw/config`
  - `${AGENTIC_ROOT}/optional/openclaw/state`
  - `${AGENTIC_ROOT}/optional/openclaw/sandbox/state`
  - `${AGENTIC_ROOT}/optional/openclaw/logs`
- Secrets required:
  - `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`
  - `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`

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
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`
- `${AGENTIC_ROOT}/secrets/runtime/mcp.token`
- `${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token` (required by `pi-mono`)

4. OpenClaw policy files are reviewed:
- `${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt`
- `${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt`

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

Goose context verification (`optional-goose` enabled):

```bash
goose_cid="$(docker ps --filter "name=${AGENTIC_COMPOSE_PROJECT:-agentic}-optional-goose" --format '{{.ID}}' | head -n 1)"
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${goose_cid}" | grep '^GOOSE_CONTEXT_LIMIT='
goose_context_limit="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${goose_cid}" | sed -n 's/^GOOSE_CONTEXT_LIMIT=//p' | head -n 1)"
goose_context_display="$((goose_context_limit / 1000))k"
timeout 12 docker exec "${goose_cid}" sh -lc 'goose session -n context-check' 2>&1 | grep "/${goose_context_display}"
```

OpenClaw gateway port check (only applicable if you run the upstream gateway variant):

```bash
lsof -nP -iTCP -sTCP:LISTEN | egrep ':(18789|18791|18792|188[0-9]{2})'
ss -lntp | egrep ':(18789|18791|18792|188[0-9]{2})'
```

## Security Notes

- Optional modules are still loopback-only where host ports are published.
- `docker.sock` mounts remain forbidden, including optional modules.
- Baseline hardening is preserved (`cap_drop: ALL`, `no-new-privileges`, read-only root filesystem where applicable).
- All optional service egress remains aligned with proxy-based policy when enabled in the baseline.
