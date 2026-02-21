# Runbook: First-Time Setup (Step by Step)

This guide is for a fresh machine with Docker already installed.
It explains:
- what must be defined before first use,
- the order to initialize the runtime,
- how to start the full baseline stack for the first time.

The baseline "whole stack" in this guide is:
- `core`
- `agents`
- `ui`
- `obs`
- `rag`

Optional modules are covered at the end.

## 1. Decide Your Profile

Choose one profile first:
- `strict-prod`: production-like mode (CDC acceptance path), root under `/srv/agentic`.
- `rootless-dev`: local non-root mode, root under `${HOME}/.local/share/agentic`.

Set it in your shell:

```bash
export AGENTIC_PROFILE=strict-prod
# or:
# export AGENTIC_PROFILE=rootless-dev
```

Confirm effective runtime values:

```bash
./agent profile
```

Tip: extract the effective runtime root for copy/paste operations:

```bash
ROOT="$(./agent profile | sed -n 's/^root=//p')"
echo "${ROOT}"
```

## 2. Define Required Configuration Before First Start

Define or review these items before running the full stack.

### 2.1 Security-sensitive credentials

1. Grafana admin password (recommended before starting `obs`):

```bash
export GRAFANA_ADMIN_PASSWORD='replace-with-strong-password'
```

2. OpenWebUI admin credentials (`openwebui.env`, created during `ui` init):
- file: `${AGENTIC_ROOT}/openwebui/config/openwebui.env`
- keys:
  - `OPENWEBUI_ADMIN_EMAIL`
  - `OPENWEBUI_ADMIN_PASSWORD`

3. OpenHands model/API settings (`openhands.env`, created during `ui` init):
- file: `${AGENTIC_ROOT}/openhands/config/openhands.env`
- keys:
  - `OPENHANDS_LLM_MODEL`
  - `OPENHANDS_LLM_API_KEY`

### 2.2 Egress allowlist (important for agent outbound access)

- file: `${AGENTIC_ROOT}/proxy/allowlist.txt`
- default template is intentionally minimal.
- add only domains required for your workflows.

If the allowlist is too strict, agents/UI that need external APIs will fail outbound calls by design.

### 2.3 Optional module secrets (only if you plan to enable optionals)

Required files:
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`
- `${AGENTIC_ROOT}/secrets/runtime/mcp.token`

Permissions must be restrictive (`600` or `640`).

### 2.4 Optional host telemetry mount overrides (`obs`)

If your host filesystem layout differs from defaults, set these before `./agent up obs`:
- `PROMTAIL_DOCKER_CONTAINERS_HOST_PATH` (default `/var/lib/docker/containers`)
- `PROMTAIL_HOST_LOG_PATH` (default `/var/log`)
- `NODE_EXPORTER_HOST_ROOT_PATH` (default `/`)
- `CADVISOR_HOST_ROOT_PATH` (default `/`)
- `CADVISOR_DOCKER_LIB_HOST_PATH` (default `/var/lib/docker`)
- `CADVISOR_SYS_HOST_PATH` (default `/sys`)
- `CADVISOR_DEV_DISK_HOST_PATH` (default `/dev/disk`)

Verify effective values with:

```bash
./agent profile
```

### 2.5 GitHub Git access must be non-interactive (SSH recommended)

For automation (`git pull --rebase`, `git push`, `bd sync`), Git auth must not require interactive password prompts.

Recommended path:

1. Ensure SSH key-based auth is configured and loaded in `ssh-agent`.
2. Validate non-interactive access:

```bash
GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10' \
  git ls-remote origin -h refs/heads/master
```

Expected result: command returns `0` and prints the remote ref hash without prompting.

3. Optional direct SSH check:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 -T git@github.com
```

Expected result: authentication success message (GitHub shell access remains disabled by design).

If SSH is not ready yet:

- Load the key into the agent for the current session:

```bash
ssh-add ~/.ssh/id_ed25519
ssh-add -l
```

- Fallback option: switch remote to HTTPS + PAT with a credential helper, then re-run the non-interactive check with `git ls-remote origin`.

## 3. Bootstrap Host Runtime Tree

### `strict-prod`

```bash
export AGENTIC_PROFILE=strict-prod
sudo ./deployments/bootstrap/init_fs.sh
```

### `rootless-dev`

```bash
export AGENTIC_PROFILE=rootless-dev
./deployments/bootstrap/init_fs.sh
```

This creates the runtime directory contract and base permissions.

## 4. Start Core First

`core` must start first because it provides Ollama, gate, DNS, proxy, and network policy wiring.

### `strict-prod`

```bash
sudo ./agent up core
```

### `rootless-dev`

```bash
./agent up core
```

Notes:
- In `strict-prod`, `agent up core` also applies host `DOCKER-USER` controls (unless explicitly disabled).
- In `rootless-dev`, host-level root-only checks are intentionally degraded.

## 5. Tune Runtime Config Files

After `core` is up, edit the egress allowlist:

```bash
# strict-prod
sudoedit /srv/agentic/proxy/allowlist.txt

# rootless-dev (default root)
$EDITOR "${HOME}/.local/share/agentic/proxy/allowlist.txt"
```

If you use a custom `AGENTIC_ROOT`, edit `${ROOT}/proxy/allowlist.txt` instead.

Then re-apply `core` so proxy config is reloaded cleanly:

```bash
# strict-prod
sudo ./agent up core

# rootless-dev
./agent up core
```

If you plan to use default runtime alerting, review:
- `${AGENTIC_ROOT}/monitoring/config/prometheus-alerts.yml`
- See `docs/runbooks/observability-triage.md` for the recommended queries and thresholds.

## 6. Start the Rest of the Baseline Stack

### `strict-prod`

```bash
sudo ./agent up agents,ui,obs,rag
```

### `rootless-dev`

```bash
./agent up agents,ui,obs,rag
```

During `ui` startup, runtime env files are materialized automatically if missing:
- `${AGENTIC_ROOT}/openwebui/config/openwebui.env`
- `${AGENTIC_ROOT}/openhands/config/openhands.env`

Edit them now and restart `ui` once:

```bash
# strict-prod
sudoedit /srv/agentic/openwebui/config/openwebui.env
sudoedit /srv/agentic/openhands/config/openhands.env
sudo ./agent up ui

# rootless-dev
$EDITOR "${HOME}/.local/share/agentic/openwebui/config/openwebui.env"
$EDITOR "${HOME}/.local/share/agentic/openhands/config/openhands.env"
./agent up ui
```

If you use a custom `AGENTIC_ROOT`, edit `${ROOT}/openwebui/config/openwebui.env` and `${ROOT}/openhands/config/openhands.env`.

## 7. Create First Tracked Release Snapshot

`agent up` now creates an automatic bootstrap snapshot when no active release exists yet.
For operational traceability after pulls/image refresh, run `agent update` once after first successful startup:

### `strict-prod`

```bash
sudo ./agent update
```

### `rootless-dev`

```bash
./agent update
```

This records the deployed image digests and effective config in:
- `${AGENTIC_ROOT}/deployments/releases/...`
- `${AGENTIC_ROOT}/deployments/current`

## 8. Validate Health and Compliance

### `strict-prod`

```bash
sudo ./agent doctor
sudo ./agent ls
```

### `rootless-dev`

```bash
./agent doctor
./agent ls
```

If `doctor` fails, fix the reported item first (bind scope, healthcheck, security flags, policy checks, or release manifest).

## 9. First Access

Local URLs (on the host):
- OpenWebUI: `http://127.0.0.1:8080`
- OpenHands: `http://127.0.0.1:3000`
- ComfyUI: `http://127.0.0.1:8188`
- Grafana: `http://127.0.0.1:13000`
- Prometheus: `http://127.0.0.1:19090`
- Loki: `http://127.0.0.1:13100`

Remote access pattern is Tailscale + SSH tunnel to host loopback (not direct LAN/public binds).

## 10. Optional Modules (Later, Explicit Opt-In)

Do not enable optional modules until baseline is green.

Activation pattern:

```bash
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
```

or:

```bash
AGENTIC_OPTIONAL_MODULES=mcp,pi-mono,goose,portainer ./agent up optional
```

Before activation:
- fill `${AGENTIC_ROOT}/deployments/optional/*.request` (`need=`, `success=`),
- place required tokens/secrets in `${AGENTIC_ROOT}/secrets/runtime/`,
- review OpenClaw allowlists:
  - `${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt`
  - `${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt`
- run `./agent doctor` and confirm baseline readiness.

See:
- `docs/runbooks/optional-modules.md`

## 11. One-Command Baseline Start (After Initial Setup)

Once configuration is settled, normal startup is:

### `strict-prod`

```bash
sudo ./agent up core
sudo ./agent up agents,ui,obs,rag
sudo ./agent doctor
```

### `rootless-dev`

```bash
./agent up core
./agent up agents,ui,obs,rag
./agent doctor
```
