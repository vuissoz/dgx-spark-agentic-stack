# DGX Spark Agentic Stack

This repository provides a containerized agentic services stack for DGX Spark, with:
- local-only exposure (`127.0.0.1` binds),
- egress control (proxy + DOCKER-USER in `strict-prod`),
- baseline hardening (`read_only`, `cap_drop: ALL`, `no-new-privileges`),
- release snapshots + rollback,
- orchestration through a single command: `./agent`.

## Compose Stacks

Compose files are located in `compose/`:
- `compose/compose.core.yml`: `ollama`, `ollama-gate`, `gate-mcp`, `trtllm` (`trt` profile), `unbound`, `egress-proxy`, `toolbox`
- `compose/compose.agents.yml`: `agentic-claude`, `agentic-codex`, `agentic-opencode`, `agentic-vibestral`
- `compose/compose.ui.yml`: `openwebui`, `openhands`, `comfyui`
- `compose/compose.obs.yml`: `prometheus`, `grafana`, `loki`, exporters
- `compose/compose.rag.yml`: `qdrant`, `rag-retriever`, `rag-worker`, `opensearch` (`rag-lexical` profile)
- `compose/compose.optional.yml`: `optional-sentinel`, `optional-openclaw`, `optional-openclaw-sandbox`, `optional-mcp-catalog`, `optional-pi-mono`, `optional-goose`, `optional-portainer`

## Execution Profiles

The profile is controlled by `AGENTIC_PROFILE`:
- `strict-prod` (default): runtime under `/srv/agentic`, host `DOCKER-USER` checks enabled.
- `rootless-dev`: runtime under `${HOME}/.local/share/agentic`, root-only host checks degraded.

Check with:

```bash
./agent profile
```

Optional TRT-LLM backend activation (internal-only):

```bash
export COMPOSE_PROFILES=trt
./agent up core
```

Model-to-backend routing remains centralized in `ollama-gate` via `${AGENTIC_ROOT}/gate/config/model_routes.yml`.

## Runtime Layout (summary)

Runtime root:
- `strict-prod`: `/srv/agentic`
- `rootless-dev`: `${HOME}/.local/share/agentic`

Key persistent folders:
- `ollama/`
- `gate/{config,state,logs,mcp/{state,logs}}/`
- `trtllm/{models,state,logs}/`
- `proxy/{config,logs}/`
- `dns/`
- `openwebui/`
- `openhands/{config,state,logs,workspaces}/`
- `comfyui/{models,input,output,user}/`
- `rag/{qdrant,qdrant-snapshots,docs,scripts,retriever/{state,logs},worker/{state,logs},opensearch,opensearch-logs}/`
- `{claude,codex,opencode,vibestral}/{state,logs,workspaces}/`
- `optional/{openclaw,mcp,pi-mono,goose,portainer}/...`
- `deployments/{releases,current}/`
- `secrets/`
- `shared-ro/`, `shared-rw/`

## Host Path Variables (mounts)

Host mounts used by the stack are configurable through environment variables.
Application persistent paths remain under `${AGENTIC_ROOT}`.

For observability (host telemetry mounts), available variables are:
- `PROMTAIL_DOCKER_CONTAINERS_HOST_PATH` (default: `/var/lib/docker/containers`)
- `PROMTAIL_HOST_LOG_PATH` (default: `/var/log`)
- `NODE_EXPORTER_HOST_ROOT_PATH` (default: `/`)
- `CADVISOR_HOST_ROOT_PATH` (default: `/`)
- `CADVISOR_DOCKER_LIB_HOST_PATH` (default: `/var/lib/docker`)
- `CADVISOR_SYS_HOST_PATH` (default: `/sys`)
- `CADVISOR_DEV_DISK_HOST_PATH` (default: `/dev/disk`)

Override example before startup:

```bash
export AGENTIC_PROFILE=rootless-dev
export PROMTAIL_HOST_LOG_PATH=/var/log
export NODE_EXPORTER_HOST_ROOT_PATH=/
./agent profile
./agent up obs
```

`./agent profile` shows the effective values in use.

## Agent Base Image Override (E1b)

Agent services (`agentic-claude`, `agentic-codex`, `agentic-opencode`, `agentic-vibestral`) share a common runtime-configurable base image.

By default, `deployments/images/agent-cli-base/Dockerfile` builds a CUDA-based (NVIDIA) development image with a multi-language toolchain (C/C++, Python, Node, Go, Rust).

Supported variables:
- `AGENTIC_AGENT_BASE_IMAGE` (default: `agentic/agent-cli-base:local`)
- `AGENTIC_AGENT_BASE_BUILD_CONTEXT` (default: repository root)
- `AGENTIC_AGENT_BASE_DOCKERFILE` (default: `deployments/images/agent-cli-base/Dockerfile`)

Minimal custom Dockerfile contract:
- non-root default user,
- explicit `ENTRYPOINT` compatible with persistent tmux sessions,
- baseline tools available: `bash`, `tmux`, `git`, `curl`.

The default Dockerfile also accepts an `AGENT_BASE_IMAGE` build arg to change the CUDA base (tag/digest) while keeping the rest of the toolchain setup.

Example:

```bash
export AGENTIC_AGENT_BASE_IMAGE=agentic/agent-cli-base:custom
export AGENTIC_AGENT_BASE_BUILD_CONTEXT=/opt/agent-images/custom-base
export AGENTIC_AGENT_BASE_DOCKERFILE=/opt/agent-images/custom-base/Dockerfile
./agent up agents
```

Effective values are shown by `./agent profile` and persisted into `${AGENTIC_ROOT}/deployments/runtime.env`.

## Prerequisites

- Linux + Docker Engine
- Docker Compose v2 (`docker compose`)
- Multipass (`multipass`) for VM commands (`agent vm create`, `agent vm test`)
- NVIDIA Container Toolkit (for GPU services)
- `iptables` available (in `strict-prod` for `DOCKER-USER`)
- `acl` / `setfacl` recommended in `rootless-dev` (Squid log ACLs)

## Quick Start

### `strict-prod`

```bash
export AGENTIC_PROFILE=strict-prod
sudo ./deployments/bootstrap/init_fs.sh
sudo ./agent up core
sudo ./agent up agents,ui,obs,rag
sudo ./agent doctor
```

### `rootless-dev`

```bash
export AGENTIC_PROFILE=rootless-dev
./deployments/bootstrap/init_fs.sh
./agent ollama-link
./agent up core
./agent up agents,ui,obs,rag
./agent doctor
```

## Remote Access (Tailscale + SSH tunnel)

Services are bound on `127.0.0.1` on the host.
Consequence: from another machine (even on the same Tailscale network), `http://<tailscale-host-ip>:8080` will not work directly.

The expected access mode is an SSH tunnel from client to DGX host:

```bash
ssh -N \
  -L 8080:127.0.0.1:8080 \
  -L 3000:127.0.0.1:3000 \
  -L 8188:127.0.0.1:8188 \
  -L 13000:127.0.0.1:13000 \
  -L 19090:127.0.0.1:19090 \
  -L 13100:127.0.0.1:13100 \
  <user>@<tailscale-hostname-or-ip>
```

Then, on the client machine, open:
- `http://127.0.0.1:8080` (OpenWebUI)
- `http://127.0.0.1:3000` (OpenHands)
- `http://127.0.0.1:8188` (ComfyUI)
- `http://127.0.0.1:13000` (Grafana)
- `http://127.0.0.1:19090` (Prometheus)
- `http://127.0.0.1:13100` (Loki)

Useful ports to tunnel (depending on enabled modules):
- `11434` -> Ollama API (`http://127.0.0.1:11434`)
- `8080` -> OpenWebUI (`http://127.0.0.1:8080`)
- `3000` -> OpenHands (`http://127.0.0.1:3000`)
- `8188` -> ComfyUI (`http://127.0.0.1:8188`)
- `13000` -> Grafana (`http://127.0.0.1:13000`)
- `19090` -> Prometheus (`http://127.0.0.1:19090`)
- `13100` -> Loki (`http://127.0.0.1:13100`)
- `9001` -> optional Portainer (`http://127.0.0.1:9001`)
- `18111` -> optional OpenClaw webhook ingress (`http://127.0.0.1:18111`)

Notes:
- tunnel only the ports you need;
- host ports are configurable via environment variables (`*_HOST_PORT`);
- `qdrant` is not published on a host port in the current configuration;
- `rag-retriever` (`7111`) and `rag-worker` (`7112`) are never host-published;
- `opensearch` (`rag-lexical`) remains internal-only (no host-published port);
- `optional-openclaw` only publishes local webhook ingress (`127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`), never `0.0.0.0`.

OpenClaw upstream behavior if deploying the official gateway:
- gateway: `18789` (control plane + HTTP APIs + Control UI + WebSocket RPC on one port),
- browser control service: `18791` (`gateway.port + 2`),
- relay: `18792` (`gateway.port + 3`),
- local CDP (managed browser profiles): `18800-18899` by default.

Common point of confusion:
- a node (`openclaw node run`) connects outbound to the gateway (WebSocket) and does not require a new inbound gateway port.

Quick check (Linux/macOS host):

```bash
lsof -nP -iTCP -sTCP:LISTEN | egrep ':(18789|18791|18792|188[0-9]{2})'
ss -lntp | egrep ':(18789|18791|18792|188[0-9]{2})'
```

### iPhone

Yes, this is possible with an iOS SSH app that supports local port forwarding (for example: Termius, Blink Shell, Prompt).
Same principle: create a local tunnel to host `127.0.0.1:<port>`, then open `http://127.0.0.1:<port>` from iPhone (Safari or the app browser).

## `agent` Commands

Supported commands:

```text
agent profile
agent up <core|agents|ui|obs|rag|optional>
agent down <core|agents|ui|obs|rag|optional>
agent stack <start|stop> <core|agents|ui|obs|rag|optional|all>
agent <claude|codex|opencode|vibestral> [project]
agent ls
agent ps
agent llm mode [local|hybrid|remote]
agent logs <service>
agent stop <tool>
agent stop service <service...>
agent stop container <container...>
agent start service <service...>
agent start container <container...>
agent backup <run|list|restore <snapshot_id> [--yes]>
agent forget <target> [--yes] [--no-backup]
agent cleanup [--yes] [--backup|--no-backup]
agent net apply
agent ollama-link
agent ollama-preload [--generate-model <model>] [--embed-model <model>] [--budget-gb <int>] [--no-lock-ro]
agent ollama-models <rw|ro>
agent update
agent rollback all <release_id>
agent rollback host-net <backup_id>
agent rollback ollama-link <backup_id|latest>
agent onboard [--profile ... --root ... --compose-project ... --network ... --egress-network ... --ollama-models-dir ... --limits-default-cpus ... --limits-default-mem ... --limits-core-cpus ... --limits-core-mem ... --limits-agents-cpus ... --limits-agents-mem ... --limits-ui-cpus ... --limits-ui-mem ... --limits-obs-cpus ... --limits-obs-mem ... --limits-rag-cpus ... --limits-rag-mem ... --limits-optional-cpus ... --limits-optional-mem ... --output ... --non-interactive]
agent vm create [--name ... --cpus ... --memory ... --disk ... --image ... --reuse-existing --mount-repo|--no-mount-repo --require-gpu --skip-bootstrap --dry-run]
agent vm test [--name ... --workspace-path ... --test-selectors ... --require-gpu|--allow-no-gpu --dry-run]
agent test <A|B|C|D|E|F|G|H|I|J|K|L|V|all>
agent doctor [--fix-net]
```

Examples:

```bash
./agent up core
./agent up agents,ui
./agent codex my-project
./agent logs ollama
./agent stop codex
./agent backup run
./agent backup list
./agent update
./agent rollback all <release_id>
```

Notes:
- `agent stop` handles `claude|codex|opencode|vibestral` tools.
- `agent rollback all` requires a `release_id`.

## Ollama: preload and model link

In `rootless-dev`, the local model symlink is managed via:

```bash
./agent ollama-link
```

Preload then switch to read-only for smoke tests:

```bash
./agent ollama-preload
./agent ollama-models ro
./agent ollama-models rw
```

Model link rollback:

```bash
./agent rollback ollama-link <backup_id|latest>
```

## External LLM Routing (D5)

`ollama-gate` can route selected models to `openai`/`openrouter` while keeping a stable client API (`/v1/*`).

Runtime prerequisites:
- API keys outside git:
  - `${AGENTIC_ROOT}/secrets/runtime/openai.api_key`
  - `${AGENTIC_ROOT}/secrets/runtime/openrouter.api_key`
- explicit egress allowlist:
  - `${AGENTIC_ROOT}/proxy/allowlist.txt` must include `api.openai.com` and `openrouter.ai`

## LLM Modes + External Quotas (D6)

- `./agent llm mode local`: explicitly blocks external providers.
- `./agent llm mode hybrid`: local-first with external providers allowed by routing policy.
- `./agent llm mode remote`: external providers allowed, with the option to stop `ollama`/`trtllm` to free GPU/RAM.

Example `remote` mode with local pause:

```bash
./agent llm mode remote
./agent stop service ollama trtllm
```

Runtime state:
- mode: `${AGENTIC_ROOT}/gate/state/llm_mode.json`
- quota counters: `${AGENTIC_ROOT}/gate/state/quotas_state.json`
- metrics: `external_requests_total`, `external_tokens_total`, `external_quota_remaining`

## Local MCP `gate-mcp` (D7)

`gate-mcp` is part of the `core` stack and remains internal-only (no host-published port).  
It exposes `/v1/tools/execute` with:
- `gate.current_model`
- `gate.quota_remaining`
- `gate.switch_model`

D7 hardening:
- required local auth (`Authorization: Bearer ...`) via `${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token`
- minimal service-side rate limiting
- JSONL audit trail: `${AGENTIC_ROOT}/gate/mcp/logs/audit.jsonl`

Injected into agent containers:
- `GATE_MCP_URL=http://gate-mcp:8123`
- `GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token`

## Optional Modules

Explicit activation:

```bash
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
AGENTIC_OPTIONAL_MODULES=mcp,pi-mono,goose,portainer ./agent up optional
```

Runtime prerequisites:
- request files: `${AGENTIC_ROOT}/deployments/optional/*.request`
  - `${AGENTIC_ROOT}/deployments/optional/openclaw.request`
  - `${AGENTIC_ROOT}/deployments/optional/mcp.request`
  - `${AGENTIC_ROOT}/deployments/optional/pi-mono.request`
  - `${AGENTIC_ROOT}/deployments/optional/goose.request`
  - `${AGENTIC_ROOT}/deployments/optional/portainer.request`
- secrets:
  - `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`
  - `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`
  - `${AGENTIC_ROOT}/secrets/runtime/mcp.token`

## Validation

- Global diagnostics: `./agent doctor`
- Test campaigns: `./agent test <A..L|V|all>`
- VM `strict-prod` campaign (evidence + update/rollback + tests): `./agent vm test --name agentic-strict-prod`
- Check VM state: `multipass list` then `multipass info <vm-name>` (`State: Running` expected)

## Detailed Documentation

- Introduction (stack philosophy and operating model):
  - `docs/runbooks/introduction.md`
- Step-by-step guide (full first deployment):
  - `docs/runbooks/first-time-setup.md`
- Dedicated `strict-prod` VM (prod-like validation):
  - `docs/runbooks/strict-prod-vm.md`
- Feature and implemented agent catalog:
  - `docs/runbooks/features-and-agents.md`
- Beginner service-by-service guide (French):
  - `docs/runbooks/services-expliques-debutants.md`
- Beginner service-by-service guide (English):
  - `docs/runbooks/services-explained-beginners.en.md`
- Beginner configuration reference (French):
  - `docs/runbooks/configuration-expliquee-debutants.md`
- Beginner configuration reference (English):
  - `docs/runbooks/configuration-explained-beginners.en.md`
- Ultra-simplified non-technical onboarding (FR/EN/DE/IT):
  - `docs/runbooks/onboarding-ultra-simple.fr.md`
  - `docs/runbooks/onboarding-ultra-simple.en.md`
  - `docs/runbooks/onboarding-ultra-simple.de.md`
  - `docs/runbooks/onboarding-ultra-simple.it.md`
- Execution profiles:
  - `docs/runbooks/profiles.md`
- Optional modules:
  - `docs/runbooks/optional-modules.md`
- Observability triage (latency, egress errors, restarts, OOM):
  - `docs/runbooks/observability-triage.md`
- OpenClaw security model (sandbox + controlled egress, no `docker.sock`):
  - `docs/security/openclaw-sandbox-egress.md`

## Internal References

- `AGENTS.md`
- `PLAN.md`
- `docs/runbooks/*.md`
- `docs/decisions/*.md`
