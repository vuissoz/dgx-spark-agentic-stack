# Runbook: Configuration Explained for Beginners

This runbook is the configuration reference for the stack.
It explains:
- what can be configured,
- allowed values,
- where each value is stored,
- how to handle secrets and API keys safely.

Use this document as the source of truth before changing runtime settings.

## 1. How Configuration Works

Configuration comes from 5 places:

1. Shell environment variables
- Example: `export AGENTIC_PROFILE=strict-prod`

2. Generated onboarding file
- Default output: `.runtime/env.generated.sh`
- Produced by: `./agent onboard ...`
- You load it with: `source .runtime/env.generated.sh`

3. Runtime state file (managed by `agent`)
- File: `${AGENTIC_ROOT}/deployments/runtime.env`
- Updated automatically by commands like `agent up`, `agent llm mode`, `agent llm test-mode`, `agent ollama-models`, `agent ollama-preload`.

4. Service config files under `${AGENTIC_ROOT}`
- Example: `${AGENTIC_ROOT}/proxy/allowlist.txt`
- Example: `${AGENTIC_ROOT}/gate/config/model_routes.yml`

5. Secret files under `${AGENTIC_ROOT}/secrets/runtime`
- Example: `${AGENTIC_ROOT}/secrets/runtime/openai.api_key`

Important behavior:
- For many core variables, `runtime.env` is loaded by `./agent` and becomes the effective value.
- If a key is in `runtime.env`, changing only your shell may not be enough; update `runtime.env` via `agent` commands or edit it intentionally.

## 2. Beginner Safe Defaults (What To Choose)

If you are unsure, use these defaults:

- Profile:
  - `strict-prod` for production-like operation.
  - `rootless-dev` for local development without root.

- LLM mode:
  - `hybrid` for most users.
  - `local` if you want to fully block external providers.
  - `remote` if you rely on external providers and want to free local GPU/RAM.

- Optional modules:
  - Keep disabled by default.
  - Enable only after `./agent doctor` is green.

- Model store mount mode:
  - `rw` while preloading/updating models.
  - `ro` for deterministic smoke tests.

## 3. Variable Catalog

## 3.1 Core Runtime Identity

| Variable | Allowed values | Default (`strict-prod`) | Default (`rootless-dev`) | Stored in |
|---|---|---|---|---|
| `AGENTIC_PROFILE` | `strict-prod` or `rootless-dev` | `strict-prod` | `rootless-dev` when exported | shell, `runtime.env` |
| `AGENTIC_ROOT` | absolute path | `/srv/agentic` | `${HOME}/.local/share/agentic` | shell, `runtime.env` |
| `AGENTIC_COMPOSE_PROJECT` | Compose project name (`[a-zA-Z0-9][a-zA-Z0-9_.-]*`) | `agentic` | `agentic-dev` | shell, `runtime.env` |
| `AGENTIC_NETWORK` | Docker network name | `agentic` | `agentic-dev` | shell, `runtime.env` |
| `AGENTIC_LLM_NETWORK` | Docker network name | `agentic-llm` | `agentic-dev-llm` | shell, `runtime.env` |
| `AGENTIC_EGRESS_NETWORK` | Docker network name | `agentic-egress` | `agentic-dev-egress` | shell, `runtime.env` |

## 3.2 Stack Selection and Compose Profiles

| Variable | Allowed values | Default | Stored in |
|---|---|---|---|
| `AGENTIC_STACK_ALL_TARGETS` | comma list of `core,agents,ui,obs,rag,optional` (subset allowed) | `core,agents,ui,obs,rag,optional` | shell |
| `AGENTIC_OPTIONAL_MODULES` | comma list of `openclaw,mcp,pi-mono,goose,portainer` | empty (none enabled) | shell |
| `COMPOSE_PROFILES` | comma list. Supported in repo: `trt`, `rag-lexical` | empty | shell |

Notes:
- `trt` enables `trtllm` in `core`.
- `rag-lexical` enables `opensearch` in `rag`.

## 3.3 LLM Routing, Quotas, and MCP Limits

| Variable | Allowed values | Default | Stored in |
|---|---|---|---|
| `AGENTIC_LLM_MODE` | `local`, `hybrid`, `remote` | `hybrid` | `runtime.env`, `${AGENTIC_ROOT}/gate/state/llm_mode.json` |
| `GATE_ENABLE_TEST_MODE` | `0` (off) or `1` (on) | `0` | `runtime.env` |
| `AGENTIC_OPENAI_DAILY_TOKENS` | integer `>= 0` (`0` means unlimited/off) | `0` | `runtime.env` |
| `AGENTIC_OPENAI_MONTHLY_TOKENS` | integer `>= 0` | `0` | `runtime.env` |
| `AGENTIC_OPENAI_DAILY_REQUESTS` | integer `>= 0` | `0` | `runtime.env` |
| `AGENTIC_OPENAI_MONTHLY_REQUESTS` | integer `>= 0` | `0` | `runtime.env` |
| `AGENTIC_OPENROUTER_DAILY_TOKENS` | integer `>= 0` | `0` | `runtime.env` |
| `AGENTIC_OPENROUTER_MONTHLY_TOKENS` | integer `>= 0` | `0` | `runtime.env` |
| `AGENTIC_OPENROUTER_DAILY_REQUESTS` | integer `>= 0` | `0` | `runtime.env` |
| `AGENTIC_OPENROUTER_MONTHLY_REQUESTS` | integer `>= 0` | `0` | `runtime.env` |
| `GATE_MCP_RATE_LIMIT_RPS` | float `> 0` | `5` | `runtime.env` |
| `GATE_MCP_RATE_LIMIT_BURST` | integer `>= 1` | `10` | `runtime.env` |
| `GATE_MCP_HTTP_TIMEOUT_SEC` | float `> 0` | `5` | `runtime.env` |
| `GATE_MCP_ALLOWED_MODEL_REGEX` | valid regex string (empty = default regex) | empty | `runtime.env` |

## 3.4 Model Store and Model IDs

| Variable | Allowed values | Default | Stored in |
|---|---|---|---|
| `OLLAMA_MODELS_DIR` | absolute path | `strict-prod`: `${AGENTIC_ROOT}/ollama/models`; `rootless-dev` (onboarding): `${HOME}/wkdir/open-webui/ollama_data/models` | shell, `runtime.env` |
| `AGENTIC_OLLAMA_MODELS_LINK` | absolute path (rootless symlink path) | `${REPO}/.runtime/ollama-models` | shell, `runtime.env` |
| `AGENTIC_OLLAMA_MODELS_TARGET_DIR` | absolute path (rootless real target) | `${REPO}/.runtime/ollama-models-data` (or value derived from `OLLAMA_MODELS_DIR` when onboarding provides one) | shell, `runtime.env` |
| `OLLAMA_CONTAINER_MODELS_PATH` | container path | `/root/.ollama/models` | `/tmp/ollama/models` in `rootless-dev` |
| `OLLAMA_MODELS_MOUNT_MODE` | `rw` or `ro` | `rw` | `runtime.env` |
| `AGENTIC_DEFAULT_MODEL` | model id string | `llama3.1:8b` | shell, `runtime.env` |
| `OLLAMA_PRELOAD_GENERATE_MODEL` | model id string | `${AGENTIC_DEFAULT_MODEL}` (fallback `llama3.1:8b`) | `runtime.env` |
| `OLLAMA_PRELOAD_EMBED_MODEL` | model id string | `qwen3-embedding:0.6b` | `runtime.env` |
| `OLLAMA_MODEL_STORE_BUDGET_GB` | positive integer | `12` | `runtime.env` |
| `RAG_EMBED_MODEL` | model id string | `qwen3-embedding:0.6b` | `runtime.env` |
| `TRTLLM_MODELS` | model route selector string | `qwen3-nvfp4-demo` | shell |
| `COMFYUI_REF` | git ref for ComfyUI image build | `master` | shell |
| `COMFYUI_MANAGER_REPO` | ComfyUI manager extension git repo (empty = disabled) | `https://github.com/ltdrdata/ComfyUI-Manager.git` | shell |
| `COMFYUI_MANAGER_REF` | ComfyUI manager extension git ref | `main` | shell |

## 3.5 Host-Published Port Variables

All published ports stay loopback-only (`127.0.0.1`).

| Variable | Service | Default |
|---|---|---|
| `OPENWEBUI_HOST_PORT` | OpenWebUI | `8080` |
| `OPENHANDS_HOST_PORT` | OpenHands | `3000` |
| `COMFYUI_HOST_PORT` | ComfyUI loopback bridge | `8188` |
| `GRAFANA_HOST_PORT` | Grafana | `13000` |
| `PROMETHEUS_HOST_PORT` | Prometheus | `19090` |
| `LOKI_HOST_PORT` | Loki | `13100` |
| `PORTAINER_HOST_PORT` | Optional Portainer | `9001` |
| `OPENCLAW_WEBHOOK_HOST_PORT` | Optional OpenClaw webhook ingress | `18111` |

## 3.6 Resource Limits

Stack-level defaults (persisted in `runtime.env`):
- `AGENTIC_LIMIT_DEFAULT_CPUS`, `AGENTIC_LIMIT_DEFAULT_MEM`
- `AGENTIC_LIMIT_CORE_CPUS`, `AGENTIC_LIMIT_CORE_MEM`
- `AGENTIC_LIMIT_AGENTS_CPUS`, `AGENTIC_LIMIT_AGENTS_MEM`
- `AGENTIC_LIMIT_UI_CPUS`, `AGENTIC_LIMIT_UI_MEM`
- `AGENTIC_LIMIT_OBS_CPUS`, `AGENTIC_LIMIT_OBS_MEM`
- `AGENTIC_LIMIT_RAG_CPUS`, `AGENTIC_LIMIT_RAG_MEM`
- `AGENTIC_LIMIT_OPTIONAL_CPUS`, `AGENTIC_LIMIT_OPTIONAL_MEM`

Dedicated onboarding prompt:
- `AGENTIC_LIMIT_OLLAMA_MEM` (default: inherits `AGENTIC_LIMIT_CORE_MEM`)

Per-service override pattern:
- `AGENTIC_LIMIT_<SERVICE_NAME>_CPUS`
- `AGENTIC_LIMIT_<SERVICE_NAME>_MEM`

Examples:
- `AGENTIC_LIMIT_OLLAMA_MEM=6g`
- `AGENTIC_LIMIT_OPENWEBUI_CPUS=0.60`
- `AGENTIC_LIMIT_OPTIONAL_OPENCLAW_MEM=768m`

Value formats:
- CPU: positive decimal (`0.5`, `1`, `2.5`)
- Memory: Docker format (`512m`, `1g`, `2G`)

## 3.7 Container User and Telemetry Mount Variables

Container user IDs:
- `AGENT_RUNTIME_UID`, `AGENT_RUNTIME_GID`
- `OLLAMA_CONTAINER_USER`, `QDRANT_CONTAINER_USER`, `GATE_CONTAINER_USER`, `TRTLLM_CONTAINER_USER`
- `PROMETHEUS_CONTAINER_USER`, `GRAFANA_CONTAINER_USER`, `LOKI_CONTAINER_USER`, `PROMTAIL_CONTAINER_USER`

Observability host mount path overrides:
- `PROMTAIL_DOCKER_CONTAINERS_HOST_PATH` (default `/var/lib/docker/containers`)
- `PROMTAIL_HOST_LOG_PATH` (default `/var/log`)
- `NODE_EXPORTER_HOST_ROOT_PATH` (default `/`)
- `CADVISOR_HOST_ROOT_PATH` (default `/`)
- `CADVISOR_DOCKER_LIB_HOST_PATH` (default `/var/lib/docker`)
- `CADVISOR_SYS_HOST_PATH` (default `/sys`)
- `CADVISOR_DEV_DISK_HOST_PATH` (default `/dev/disk`)

## 3.8 Operational Toggles and Advanced Controls

Common toggles (`0` or `1`):
- `AGENTIC_SKIP_DOCKER_USER_APPLY`
- `AGENTIC_SKIP_DOCKER_USER_CHECK`
- `AGENTIC_SKIP_DOCTOR_PROXY_CHECK`
- `AGENTIC_SKIP_OPTIONAL_GATING`
- `AGENTIC_SKIP_CORE_IMAGE_BUILD`
- `AGENTIC_SKIP_AGENT_IMAGE_BUILD`
- `AGENTIC_SKIP_OPTIONAL_IMAGE_BUILD`
- `AGENTIC_DISABLE_AUTO_SNAPSHOT`

Other useful operational variables:
- `AGENT_LOG_TAIL` (default `200` for `agent logs`)
- `AGENT_PROJECT_NAME` (one-shot override for the current shell invocation)
- `AGENTIC_CLAUDE_WORKSPACES_DIR` (host path mounted to `/workspace` for `agentic-claude`)
- `AGENTIC_CODEX_WORKSPACES_DIR` (host path mounted to `/workspace` for `agentic-codex`)
- `AGENTIC_OPENCODE_WORKSPACES_DIR` (host path mounted to `/workspace` for `agentic-opencode`)
- `AGENTIC_VIBESTRAL_WORKSPACES_DIR` (host path mounted to `/workspace` for `agentic-vibestral`)
- `AGENT_NO_ATTACH=1` (prepare tmux session without attaching)
- `AGENTIC_DOCTOR_CRITICAL_PORTS` (comma list of ports for loopback checks)

Backup retention:
- `AGENTIC_BACKUP_KEEP_HOURLY` (default `24`)
- `AGENTIC_BACKUP_KEEP_DAILY` (default `14`)
- `AGENTIC_BACKUP_KEEP_WEEKLY` (default `8`)

Host firewall/egress advanced options:
- `AGENTIC_DOCKER_USER_CHAIN`
- `AGENTIC_DOCKER_USER_SOURCE_NETWORKS` (default: `${AGENTIC_NETWORK},${AGENTIC_EGRESS_NETWORK}`)
- `AGENTIC_DOCKER_USER_LOG_PREFIX`
- `AGENTIC_PROXY_SERVICE`, `AGENTIC_PROXY_PORT`
- `AGENTIC_UNBOUND_SERVICE`, `AGENTIC_UNBOUND_PORT`
- `AGENTIC_GATE_SERVICE`, `AGENTIC_GATE_PORT`
- `AGENTIC_OLLAMA_SERVICE`, `AGENTIC_OLLAMA_PORT`
- `AGENTIC_SERVICE_IP_RESOLVE_ATTEMPTS`, `AGENTIC_SERVICE_IP_RESOLVE_SLEEP_SECONDS`
- `AGENTIC_SKIP_HOST_NET_BACKUP`
- `AGENTIC_ALLOW_NON_ROOT_NET_ADMIN`

## 3.9 Agent Image Overrides and Admin Credentials

| Variable | Allowed values | Default | Stored in |
|---|---|---|---|
| `AGENTIC_AGENT_BASE_IMAGE` | Docker image reference | `agentic/agent-cli-base:local` | shell, `runtime.env` |
| `AGENTIC_AGENT_BASE_BUILD_CONTEXT` | absolute path or repo-relative path | repo root | shell, `runtime.env` |
| `AGENTIC_AGENT_BASE_DOCKERFILE` | absolute path or repo-relative path | `deployments/images/agent-cli-base/Dockerfile` | shell, `runtime.env` |
| `AGENTIC_AGENT_CLI_INSTALL_MODE` | `best-effort` or `required` | `best-effort` | shell, `runtime.env` |
| `AGENTIC_AGENT_NO_NEW_PRIVILEGES` | `true` or `false` | `true` | shell, `runtime.env` |
| `AGENTIC_CODEX_CLI_NPM_SPEC` | npm package spec | `@openai/codex@latest` | shell, `runtime.env` |
| `AGENTIC_CLAUDE_CODE_NPM_SPEC` | npm package spec | `@anthropic-ai/claude-code@latest` | shell, `runtime.env` |
| `AGENTIC_OPENCODE_NPM_SPEC` | npm package spec | `opencode-ai@latest` | shell, `runtime.env` |
| `AGENTIC_OPENHANDS_INSTALL_SCRIPT` | installer script URL | `https://install.openhands.dev/install.sh` | shell, `runtime.env` |
| `AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT` | installer script URL | `https://openclaw.ai/install-cli.sh` | shell, `runtime.env` |
| `AGENTIC_OPENCLAW_INSTALL_VERSION` | OpenClaw CLI version | `latest` | shell, `runtime.env` |
| `AGENTIC_VIBE_INSTALL_SCRIPT` | installer script URL | `https://mistral.ai/vibe/install.sh` | shell, `runtime.env` |
| `GRAFANA_ADMIN_USER` | non-empty string | `admin` | shell/secret manager |
| `GRAFANA_ADMIN_PASSWORD` | non-empty string | `change-me` | shell/secret manager |

Notes:
- `GRAFANA_ADMIN_*` are read directly by Compose for `grafana`; they are not managed as file secrets by runtime init scripts.
- `./agent onboard` now writes `GRAFANA_ADMIN_USER` and `GRAFANA_ADMIN_PASSWORD` into the generated onboarding env output (`.runtime/env.generated.sh`) and accepts `--grafana-admin-user` / `--grafana-admin-password` overrides.
- Prefer injecting `GRAFANA_ADMIN_PASSWORD` from a local secret manager (or one-shot shell export), not from a tracked file.
- `AGENTIC_AGENT_NO_NEW_PRIVILEGES=false` enables in-container `sudo` mode for `agentic-{claude,codex,opencode,vibestral}` (`./agent sudo-mode on`) with an explicit hardening tradeoff.

## 3.10 RAG Runtime Variables

| Variable | Allowed values | Default | Stored in |
|---|---|---|---|
| `RAG_COLLECTION` | index/collection name (letters, digits, `_`, `-`) | `agentic_docs` | shell |
| `RAG_LEXICAL_INDEX` | index name | `agentic_docs` | shell |
| `RAG_EMBED_MODEL` | model id string | `qwen3-embedding:0.6b` | shell, `runtime.env` |
| `RAG_GATE_DRY_RUN` | `0` or `1` | `1` | shell |
| `RAG_LEXICAL_BACKEND` | `disabled` or `opensearch` | `disabled` | shell |
| `RAG_FUSION_METHOD` | currently `rrf` | `rrf` | shell |
| `RAG_RRF_K` | integer `>= 1` | `60` | shell |
| `RAG_WORKER_BOOTSTRAP_INDEX` | `0` or `1` | `1` | shell |

Notes:
- `RAG_LEXICAL_BACKEND=opensearch` is meaningful only when `COMPOSE_PROFILES=rag-lexical` is enabled.
- `RAG_DENSE_BACKEND` exists in service code, but Compose pins it to `qdrant` in this repo baseline.

## 3.11 Setup and Script-Specific Variables

| Variable | Scope | Default | Stored in |
|---|---|---|---|
| `AGENTIC_ONBOARD_OUTPUT` | onboarding output path (`agent onboard`) | `${REPO}/.runtime/env.generated.sh` | shell |
| `AGENTIC_SKIP_OLLAMA_LINK_BACKUP` | skip model-link backup in `agent ollama-link` (`0`/`1`) | `0` | shell |
| `AGENTIC_SKIP_GROUP_CREATE` | skip host group creation in bootstrap (`0`/`1`) | `0` | shell |

These are advanced operational variables and are normally not needed for day-to-day usage.

## 4. Config Files You Should Know

Baseline files (created by runtime init scripts):

- `${AGENTIC_ROOT}/gate/config/model_routes.yml`
- `${AGENTIC_ROOT}/proxy/config/squid.conf`
- `${AGENTIC_ROOT}/proxy/allowlist.txt`
- `${AGENTIC_ROOT}/dns/unbound.conf`
- `${AGENTIC_ROOT}/openwebui/config/openwebui.env`
- `${AGENTIC_ROOT}/openhands/config/openhands.env`
- `${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt`
- `${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt`
- `${AGENTIC_ROOT}/optional/mcp/config/tool_allowlist.txt`
- `${AGENTIC_ROOT}/deployments/optional/<module>.request`

`openwebui.env` keys (sensitive file, mode `600`):
- `WEBUI_ADMIN_EMAIL`
- `WEBUI_ADMIN_PASSWORD`
- `OPENAI_API_KEY`
- `WEBUI_SECRET_KEY`

`openhands.env` keys (sensitive file, mode `600`):
- `LLM_MODEL`
- `LLM_API_KEY` (local through `ollama-gate`: any non-empty placeholder, for example `local-ollama`)
- `LLM_BASE_URL` (default `http://ollama-gate:11435/v1`)

OpenHands first-run preconfiguration:
- `${AGENTIC_ROOT}/openhands/state/settings.json` is created automatically when missing, so first login does not block on the "AI Provider Configuration" screen.

## 5. Secrets and Keys

## 5.1 Where secrets live

All file-based secrets live under:
- `${AGENTIC_ROOT}/secrets/runtime/`

Baseline + optional secret files:
- `${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token` (auto-created if missing)
- `${AGENTIC_ROOT}/secrets/runtime/openai.api_key` (optional, for OpenAI routing)
- `${AGENTIC_ROOT}/secrets/runtime/openrouter.api_key` (optional, for OpenRouter routing)
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.token` (required if `openclaw` enabled)
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret` (required if `openclaw` enabled)
- `${AGENTIC_ROOT}/secrets/runtime/mcp.token` (required if optional `mcp` enabled)

## 5.2 Required permissions

- Secret directories: `0700`
- Secret files: `0600` (or `0640` where explicitly allowed by checks)

Create secrets safely:

```bash
umask 077
mkdir -p "${AGENTIC_ROOT}/secrets/runtime"
printf '%s\n' '<token-or-key>' > "${AGENTIC_ROOT}/secrets/runtime/openai.api_key"
chmod 600 "${AGENTIC_ROOT}/secrets/runtime/openai.api_key"
```

## 5.3 Rotation process

1. Replace the secret file content.
2. Keep mode `600`.
3. Recreate the related stack plane.
- Example: `./agent up core`
- Optional module example: `AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional`
4. Run `./agent doctor`.

## 5.4 What not to do

- Do not commit secrets to git.
- Do not put secrets in tracked `.env` files inside repo.
- Do not paste secrets in issue comments or logs.

## 6. Where Values Are Persisted (Traceability)

Runtime state:
- `${AGENTIC_ROOT}/deployments/runtime.env`
- `${AGENTIC_ROOT}/gate/state/llm_mode.json`
- `${AGENTIC_ROOT}/gate/state/quotas_state.json`

Release traceability (created by snapshot/update):
- `${AGENTIC_ROOT}/deployments/releases/<release_id>/images.json`
- `${AGENTIC_ROOT}/deployments/releases/<release_id>/compose.effective.yml`
- `${AGENTIC_ROOT}/deployments/releases/<release_id>/runtime.env` (sanitized)
- `${AGENTIC_ROOT}/deployments/current` (symlink to active release)

Backups:
- `${AGENTIC_ROOT}/deployments/backups/snapshots/...`
- backup metadata includes sanitized runtime config (secret-like keys filtered).

## 7. Verification Commands

Use these commands after any config change:

```bash
./agent profile
./agent doctor
./agent ps
```

Useful targeted checks:

```bash
# Effective persisted runtime values
sed -n '1,200p' "${AGENTIC_ROOT}/deployments/runtime.env"

# Current LLM mode state file
cat "${AGENTIC_ROOT}/gate/state/llm_mode.json"

# Secret file modes
find "${AGENTIC_ROOT}/secrets/runtime" -maxdepth 1 -type f -printf '%m %p\n'
```
