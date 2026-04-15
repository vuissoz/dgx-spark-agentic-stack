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

## 0. After Reboot: Restore Session Context and Restart

After a system reboot, a new terminal session usually does not keep your previous `export` values.
In this repo, `./agent` defaults to `strict-prod` when `AGENTIC_PROFILE` is not set.
If your last deployment was `rootless-dev`, commands may appear to show an "empty" stack until you restore the same context.
If your last deployment was `strict-prod`, the most common mistake is the opposite: forgetting to re-run the same commands with `sudo`, then diagnosing a partial or empty runtime by accident.

### 0.1 Restore the last generated runtime env (recommended)

```bash
cd /home/vuissoz/wkdir/dgx-spark-agentic-stack
source .runtime/env.generated.sh
./agent profile
```

Expected: `profile=rootless-dev` and `compose_project=agentic-dev` if you were running rootless before reboot.

If `.runtime/env.generated.sh` is missing, set profile manually:

```bash
export AGENTIC_PROFILE=rootless-dev
./agent profile
```

### 0.2 Find what is stopped

```bash
./agent ls
./agent ps
docker ps -a --filter "label=com.docker.compose.project=$(./agent profile | sed -n 's/^compose_project=//p')" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
```

- `./agent ls` shows agent tool runtime (`up/down`, tmux session state).
- `./agent ps` shows currently running containers for the active compose project.
- `docker ps -a ...` also shows exited/stopped containers in that same project.

### 0.3 Restart baseline services

```bash
./agent first-up
```

Use the same profile consistently for all commands.
`first-up` runs this full sequence in order:
- load `.runtime/env.generated.sh` automatically when present,
- `agent profile`,
- `deployments/bootstrap/init_fs.sh`,
- `agent up core`,
- `agent up agents,ui,obs,rag` (also converges `optional-forgejo` as part of the baseline UI stack),
- `agent doctor`.

In `strict-prod`, run with sudo:

```bash
sudo -E ./agent first-up
```

If you prefer no shell exports, prefix each call with profile directly:

```bash
./agent rootless-dev up core
./agent rootless-dev up agents,ui,obs,rag
./agent rootless-dev doctor
```

The second command also starts Forgejo and runs its bootstrap before `doctor`.

`strict-prod` equivalent:

```bash
sudo ./agent strict-prod up core
sudo ./agent strict-prod up agents,ui,obs,rag
sudo ./agent strict-prod doctor
```

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

### Optional: create a dedicated VM for `strict-prod`

If you want a prod-like validation environment isolated from your main host:

Prerequisite for this section: `multipass` must be installed on the host.

```bash
./agent vm create --name agentic-strict-prod --cpus 12 --memory 48G --disk 200G --require-gpu
```

Then connect with:

```bash
multipass shell agentic-strict-prod
```

Quick status check from host:

```bash
multipass list
multipass info agentic-strict-prod
```

Then run the full validation campaign from the host:

```bash
./agent vm test --name agentic-strict-prod
```

If this VM has no GPU passthrough but you still want a documented degraded run:

```bash
./agent vm test --name agentic-strict-prod --allow-no-gpu
```

If external API access is not available, skip only D5 with a warning:

```bash
./agent vm test --name agentic-strict-prod --allow-no-gpu --skip-d5-tests
```

When you are done with this dedicated VM:

```bash
./agent vm cleanup --name agentic-strict-prod
```

Detailed guide:
- `docs/runbooks/strict-prod-vm.md`

## 2. Define Required Configuration Before First Start

Define or review these items before running the full stack.
For the full configuration catalog (all major variables, values, storage locations, and secret handling), read:
- `docs/runbooks/configuration-expliquee-debutants.md`
- `docs/runbooks/configuration-explained-beginners.en.md`

### 2.1 Security-sensitive credentials

1. Grafana admin credentials (recommended before starting `obs`):

```bash
export GRAFANA_ADMIN_USER='admin'
export GRAFANA_ADMIN_PASSWORD='replace-with-strong-password'
```

2. OpenWebUI admin credentials (`openwebui.env`):
- file: `${AGENTIC_ROOT}/openwebui/config/openwebui.env`
- keys:
  - `WEBUI_ADMIN_EMAIL`
  - `WEBUI_ADMIN_PASSWORD`
  - `OPENAI_API_KEY`
  - `WEBUI_SECRET_KEY`
  - `ENABLE_OLLAMA_API` (default: `False`)
  - `OLLAMA_BASE_URL` (default: `http://ollama-gate:11435`)
- **must be set before your first real login attempt on OpenWebUI**
- these values are bootstrap credentials for first setup; if OpenWebUI already initialized its DB, changing this file alone does not reset existing users

3. OpenHands model/API settings (`openhands.env`, created during `ui` init):
- file: `${AGENTIC_ROOT}/openhands/config/openhands.env`
- keys:
  - `LLM_MODEL`
  - `LLM_API_KEY`
  - `LLM_BASE_URL`
- default model source: `AGENTIC_DEFAULT_MODEL` (onboarding flag: `--default-model`)
- known runtime notice: `qwen3.5:35b` is allowed but warned because this stack has observed Codex/OpenHands pseudo tool tags instead of real tool calls; treat that as an integration bug to investigate, not as upstream proof that the model lacks tool support
- for local routing through `ollama-gate`, `LLM_API_KEY` can be any non-empty placeholder (example: `local-ollama`)
- first-run preconfiguration also creates `${AGENTIC_ROOT}/openhands/state/settings.json` so OpenHands does not stop on AI provider setup screen.

### 2.2 Egress allowlist (important for agent outbound access)

- file: `${AGENTIC_ROOT}/proxy/allowlist.txt`
- onboarding default now uses the extended curated list from:
  - `examples/core/allowlist.txt`
- this list includes explicit domains for: source hosting, package registries, AI/model providers, docs, security feeds, CI/CD, cloud, observability, and scientific literature.
- keep only domains required for your real workflows (recommended hardening after first bootstrap).
- for D5 external LLM routing via `ollama-gate`, keep at least:
  - `api.openai.com`
  - `openrouter.ai`

If the allowlist is too strict, agents/UI that need external APIs will fail outbound calls by design.

### 2.3 Optional module secrets (only if you plan to enable optionals)

Required files:
- `${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token` (auto-generated for D7 local `gate-mcp`)
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.token` (required for core OpenClaw)
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret` (required for core OpenClaw)
- `${AGENTIC_ROOT}/secrets/runtime/mcp.token`
- `${AGENTIC_ROOT}/secrets/runtime/openai.api_key` (if OpenAI routing enabled)
- `${AGENTIC_ROOT}/secrets/runtime/openrouter.api_key` (if OpenRouter routing enabled)
- `${AGENTIC_ROOT}/secrets/runtime/huggingface.token` (optional, for ComfyUI Flux gated downloads)

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

### 2.5 Container CPU/RAM limits (new onboarding defaults)

The onboarding wizard now also writes resource caps:
- global fallback:
  - `AGENTIC_LIMIT_DEFAULT_CPUS`
  - `AGENTIC_LIMIT_DEFAULT_MEM`
- stack defaults:
  - `AGENTIC_LIMIT_CORE_{CPUS|MEM}`
  - `AGENTIC_LIMIT_AGENTS_{CPUS|MEM}`
  - `AGENTIC_LIMIT_UI_{CPUS|MEM}`
  - `AGENTIC_LIMIT_OBS_{CPUS|MEM}`
  - `AGENTIC_LIMIT_RAG_{CPUS|MEM}`
  - `AGENTIC_LIMIT_OPTIONAL_{CPUS|MEM}`
- dedicated Ollama memory prompt:
  - `AGENTIC_LIMIT_OLLAMA_MEM` (defaults to `AGENTIC_LIMIT_CORE_MEM` when left unchanged)

Every service can still be overridden individually with:
- `AGENTIC_LIMIT_<SERVICE_NAME>_CPUS`
- `AGENTIC_LIMIT_<SERVICE_NAME>_MEM`

Examples:
- `AGENTIC_LIMIT_OLLAMA_MEM=6g`
- `AGENTIC_LIMIT_OPENWEBUI_CPUS=0.60`
- `AGENTIC_LIMIT_OPENCLAW_MEM=768m`

Supported memory format: `512m`, `1g`, `2G`, etc.

### 2.6 GitHub Git access must be non-interactive (SSH recommended)

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

### 2.7 Recommended: run onboarding wizard before first startup

The easiest way to avoid getting stuck with default UI credentials is to run:

```bash
./agent onboard
source .runtime/env.generated.sh
./agent profile
```

During this wizard, set workspace-related values explicitly:
- `AGENTIC_AGENT_WORKSPACES_ROOT` (host directory that backs `/workspace` in agent containers)
- `AGENTIC_CLAUDE_WORKSPACES_DIR`, `AGENTIC_CODEX_WORKSPACES_DIR`, `AGENTIC_OPENCODE_WORKSPACES_DIR`, `AGENTIC_VIBESTRAL_WORKSPACES_DIR`, `AGENTIC_HERMES_WORKSPACES_DIR` (one host directory per agent container mounted to `/workspace`)
- `AGENTIC_OPENHANDS_WORKSPACES_DIR` (host directory mounted to `/workspace` for `openhands`)
- `AGENTIC_OPENCLAW_WORKSPACES_DIR`, `AGENTIC_PI_MONO_WORKSPACES_DIR`, `AGENTIC_GOOSE_WORKSPACES_DIR` (host directories mounted to `/workspace` for optional agents when enabled)

Example with explicit default local model:

```bash
./agent onboard --default-model llama3.2:1b
```

Example with explicit TRT enablement captured by onboarding:

```bash
./agent onboard --compose-profiles trt --trtllm-models https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4
```

In `rootless-dev`, onboarding now proposes the Ollama host model path:
- `${HOME}/wkdir/open-webui/ollama_data/models`
- and creates sibling `${HOME}/wkdir/open-webui/ollama_data/tmp` when writable.

When `COMPOSE_PROFILES` does not already include `trt`, the interactive wizard now asks whether to enable TRT-LLM. If you accept, it then asks for `TRTLLM_MODELS` and writes both `COMPOSE_PROFILES` and `TRTLLM_MODELS` into `.runtime/env.generated.sh`.
With the default Nemotron Cascade NVFP4 TRT selection and a non-empty `${AGENTIC_ROOT}/secrets/runtime/huggingface.token`, `./agent up core` now also prepares `${AGENTIC_ROOT}/trtllm/models/cascade_30b_nvfp4` automatically before starting `trtllm`. Progress is logged to `${AGENTIC_ROOT}/trtllm/logs/nvfp4-model-prepare.log`.

By default, `./agent onboard` writes `AGENTIC_AGENT_NO_NEW_PRIVILEGES=false` in `.runtime/env.generated.sh` (agent in-container sudo-mode enabled). If you want hardened mode, run `./agent sudo-mode off` (or export `AGENTIC_AGENT_NO_NEW_PRIVILEGES=true`) before starting `agents`.
It now also writes `GRAFANA_ADMIN_USER` and `GRAFANA_ADMIN_PASSWORD` in `.runtime/env.generated.sh` (overridable via `--grafana-admin-user` and `--grafana-admin-password`).
In interactive mode, password prompts (`GRAFANA_ADMIN_PASSWORD`, `WEBUI_ADMIN_PASSWORD`) require double entry and must match.

In `rootless-dev`, this wizard can directly create/update:
- `${AGENTIC_ROOT}/openwebui/config/openwebui.env`
- `${AGENTIC_ROOT}/openhands/config/openhands.env`
- `${AGENTIC_ROOT}/proxy/allowlist.txt`
- `${AGENTIC_ROOT}/secrets/runtime/*` (if selected)

In `strict-prod`, if `${AGENTIC_ROOT}` is not writable from your current shell, the wizard will mark file bootstrap actions as deferred; run the equivalent edits with `sudo` before first `agent up ui`.

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

`core` must start first because it provides Ollama, gate, DNS, proxy, network policy wiring, and the baseline internal control services (`gate-mcp`, `openclaw`, `openclaw-gateway`, `openclaw-sandbox`, `openclaw-relay`).

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

Before first UI login, verify the OpenWebUI/OpenHands config files:
- `${AGENTIC_ROOT}/openwebui/config/openwebui.env`
- `${AGENTIC_ROOT}/openhands/config/openhands.env`

If you already used `./agent onboard` and set non-default values, just confirm:

```bash
grep -E '^(WEBUI_ADMIN_EMAIL|WEBUI_ADMIN_PASSWORD)=' "${AGENTIC_ROOT}/openwebui/config/openwebui.env"
grep -E '^(LLM_MODEL|LLM_API_KEY|LLM_BASE_URL)=' "${AGENTIC_ROOT}/openhands/config/openhands.env"
```

If files do not exist yet (for example you skipped onboarding), do this once:
1. start `ui` to materialize templates,
2. edit credentials,
3. restart `ui`,
4. then log in.

Commands:

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

If OpenWebUI was already initialized with unwanted defaults and login keeps failing, reset its persisted state explicitly (destructive):

```bash
# strict-prod
sudo ./agent forget openwebui --yes
sudo ./agent up ui

# rootless-dev
./agent forget openwebui --yes
./agent up ui
```

Optional: set gate LLM operating mode (`hybrid` default):

```bash
./agent llm mode hybrid
# or:
# ./agent llm mode local
# ./agent llm mode remote
```

In `remote` mode, you can free local GPU/RAM while keeping gate API stable:

```bash
./agent stop service ollama trtllm
```

## 7. Create First Tracked Release Snapshot

`agent up` now creates an automatic bootstrap snapshot when no active release exists yet.
In `rootless-dev`, `agent first-up` and the following `agent doctor` do not require a
prior `agent update`; if the bootstrap snapshot still lacks `latest-resolution.json`,
doctor reports a non-blocking first-run warning.

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

Then run the dedicated default-model e2e probe:

```bash
bash tests/L5_default_model_e2e.sh
bash tests/L6_codex_model_catalog.sh
```

This validates that the configured default model is present in Ollama and responds to `hello` from:
- Ollama direct
- `ollama-gate`
- `agentic-claude`, `agentic-codex`, `agentic-opencode`, `agentic-vibestral`, `agentic-hermes`
- `openwebui`
- `openhands`

`L6` additionally validates Codex-specific bootstrap correctness:
- `~/.codex/config.toml` contains managed `model_catalog_json` for the local default model,
- catalog includes `AGENTIC_DEFAULT_MODEL`,
- `codex exec` runs without `fallback model metadata` warning.

## 9. First Access

Local URLs (on the host):
- OpenWebUI: `http://127.0.0.1:8080`
- OpenHands: `http://127.0.0.1:3000`
- ComfyUI: `http://127.0.0.1:8188`
- Grafana: `http://127.0.0.1:13000`
- Prometheus: `http://127.0.0.1:19090`
- Loki: `http://127.0.0.1:13100`

At first `obs` start, Grafana auto-loads:
- datasources: `Prometheus`, `Loki`
- dashboard: `DGX Spark Agentic Activity Overview` (UID `dgx-spark-activity`)

Remote access pattern is Tailscale + SSH tunnel to host loopback (not direct LAN/public binds).

## 10. OpenClaw Core and Optional Modules

OpenClaw now ships in `core`. Keep the remaining optional modules disabled until the baseline is green.

Start OpenClaw with the core stack:

```bash
# strict-prod
sudo ./agent up core

# rootless-dev
./agent up core
```

Remaining optional-module activation pattern:

```bash
# strict-prod
sudo AGENTIC_OPTIONAL_MODULES=mcp,pi-mono,goose,portainer ./agent up optional

# rootless-dev
AGENTIC_OPTIONAL_MODULES=mcp,pi-mono,goose,portainer ./agent up optional
```

Before activation:
- fill `${AGENTIC_ROOT}/deployments/optional/*.request` (`need=`, `success=`),
- place required tokens/secrets in `${AGENTIC_ROOT}/secrets/runtime/`,
- run onboarding so the generated env captures `GIT_FORGE_HOST_PORT`, `GIT_FORGE_ADMIN_USER`, `GIT_FORGE_SHARED_NAMESPACE`, and `GIT_FORGE_ENABLE_PUSH_CREATE`, while secrets are written separately under `${AGENTIC_ROOT}/secrets/runtime/git-forge/`; Forgejo itself is then converged by the baseline `agent up ui` / `agent up agents,ui,obs,rag` / `agent first-up` path,
- review OpenClaw allowlists:
  - `${AGENTIC_ROOT}/openclaw/config/dm_allowlist.txt`
  - `${AGENTIC_ROOT}/openclaw/config/tool_allowlist.txt`
- run `./agent doctor` with the right privilege level for your profile and confirm baseline readiness.

See:
- `docs/runbooks/optional-modules.md`

## 11. One-Command Baseline Start (After Initial Setup)

Once configuration is settled, normal startup is:

### All profiles
`first-up` is the recommended one-command path:

```bash
./agent first-up
# strict-prod:
# sudo -E ./agent first-up
```

For `strict-prod`, prefer the explicit privileged form in real operations:

```bash
sudo -E ./agent first-up
```
