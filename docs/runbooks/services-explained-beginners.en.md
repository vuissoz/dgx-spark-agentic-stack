# Runbook: Understanding the Stack Service by Service (Beginner Version)

This document is intentionally educational.
It explains, service by service, what the DGX Spark Agentic stack does, using beginner-friendly language.

Goal:
- help non-technical users (or junior technical users) understand who does what,
- provide a clear mental map of the architecture,
- provide official links for deeper reading.

This document complements `docs/runbooks/introduction.md` (the "why") and `docs/runbooks/features-and-agents.md` (the feature catalog).

## 1) Mini Glossary (useful basics)

- Service: logical definition in a Compose file (example: `openwebui`).
- Container: running instance of a service (example: `agentic-dev-openwebui-1`).
- Image: container "template" (example: `ghcr.io/open-webui/open-webui:latest`).
- Volume: persistent folder (data survives container restart).
- Docker network: internal route for containers to communicate.
- Healthcheck: automatic test that says "service is responding" or "service is not responding".
- Compose profile: activation switch (useful for optional modules).

Useful official links:
- Docker Compose (concept): https://docs.docker.com/get-started/docker-concepts/the-basics/what-is-docker-compose/
- Compose file reference: https://docs.docker.com/compose/compose-file/
- Compose profiles: https://docs.docker.com/reference/compose-file/profiles/

## 2) Very Simple High-Level View

The stack is split into 6 planes:

1. `core`: AI runtime + egress control + DNS + debug tooling.
2. `agents`: agent session containers (`claude`, `codex`, `opencode`).
3. `ui`: OpenWebUI, OpenHands, ComfyUI.
4. `obs`: Prometheus, Grafana, Loki, exporters.
5. `rag`: Qdrant vector storage.
6. `optional`: opt-in modules (OpenClaw, MCP catalog, Goose, Portainer, etc.).

Important security note:
- Host ports are published on `127.0.0.1` (loopback) only.
- So there is no direct public Internet exposure.
- Remote access is expected through SSH/Tailscale tunnel to the host.

## 3) `core` Plane (foundation)

### Service `ollama`

Simple role:
- Local model engine.
- Loads LLM models and serves generation requests.

What to remember:
- If `ollama` is down, local model generation stops for the stack.
- This is the local AI heart of the platform.

Inputs/outputs:
- Host port: `127.0.0.1:11434`.
- Persistent volume: Ollama models under `${AGENTIC_ROOT}/ollama/models` (or rootless link).

Official links:
- Ollama docs: https://docs.ollama.com/
- Ollama API: https://docs.ollama.com/api/introduction
- Official repo: https://github.com/ollama/ollama

### Service `ollama-gate`

Simple role:
- A "gateway" between applications and Ollama.
- Normalizes access, limits concurrency, manages queueing, and logs decisions.

Why it exists:
- Prevent every app from hitting Ollama directly without control.
- Keep governance simple (timeouts, logs, sticky sessions, metrics).

Inputs/outputs:
- No direct public host exposure.
- Used internally via Docker network (`http://ollama-gate:11435`).
- Persistent state/logs in `${AGENTIC_ROOT}/gate/{state,logs}`.

Official links (core technologies used):
- FastAPI: https://fastapi.tiangolo.com/
- Ollama API backend target: https://docs.ollama.com/api/introduction

### Service `unbound`

Simple role:
- DNS resolver for the stack.
- Translates domain names to IP addresses with controlled behavior.

Why it exists:
- Better DNS control in a constrained egress model.

Inputs/outputs:
- Internal service (no UI).
- Config from `${AGENTIC_ROOT}/dns/unbound.conf`.

Official links:
- Unbound documentation: https://unbound.docs.nlnetlabs.nl/
- NLnet Labs docs: https://www.nlnetlabs.nl/documentation/unbound/

### Service `egress-proxy`

Simple role:
- Outbound web gatekeeper (HTTP/HTTPS proxy).
- App services route outbound web traffic through it.

Why it exists:
- Apply egress policy (allowlist, logging, audit).
- Avoid unrestricted outbound Internet access.

Inputs/outputs:
- Internal service (no end-user UI).
- Config: `${AGENTIC_ROOT}/proxy/config/squid.conf` and `allowlist.txt`.
- Logs: `${AGENTIC_ROOT}/proxy/logs`.

Official links:
- Squid site: https://www.squid-cache.org/
- Squid docs: https://www.squid-cache.org/Doc/
- Squid FAQ: https://wiki.squid-cache.org/SquidFaq/index

### Service `toolbox`

Simple role:
- Network troubleshooting toolbox container (ping, drill, curl, tcpdump, etc.).
- Used for tests, debugging, and policy verification.

Why it exists:
- Diagnose network behavior without modifying app containers.

Inputs/outputs:
- No UI.
- Utility support container.

Official links:
- Netshoot image: https://github.com/nicolaka/netshoot

## 4) `agents` Plane (agent execution)

The 3 services below share the same model:
- they run on the local image `agentic/agent-cli-base:local`,
- they use `tmux` for long-lived sessions,
- each has separate `state/logs/workspaces` folders.

### Service `agentic-claude`

Simple role:
- Dedicated agent session for the `claude` tool.

Key idea:
- Think of this as a persistent containerized workstation, not a one-shot command.

Official links:
- Claude Code overview: https://docs.anthropic.com/en/docs/claude-code/overview
- Claude Code setup: https://docs.anthropic.com/en/docs/claude-code/setup
- tmux: https://github.com/tmux/tmux

### Service `agentic-codex`

Simple role:
- Dedicated agent session for `codex`.

Key idea:
- Same mechanics as `agentic-claude`, with OpenAI/Codex tooling.

Official links:
- Codex CLI (OpenAI Help): https://help.openai.com/en/articles/11096431
- Official Codex repo: https://github.com/openai/codex
- OpenAI developer docs: https://platform.openai.com/docs
- tmux: https://github.com/tmux/tmux

### Service `agentic-opencode`

Simple role:
- Dedicated agent session for `opencode`.

Key idea:
- Same confinement architecture as other agent containers.

Official links:
- OpenCode: https://opencode.ai/
- OpenCode CLI docs: https://opencode.ai/docs/cli/
- tmux: https://github.com/tmux/tmux

## 5) `ui` Plane (user interfaces)

### Service `openwebui`

Simple role:
- Web chat interface that uses models via `ollama-gate`.

For beginners:
- This is the most obvious conversational entry point.

Inputs/outputs:
- Host port: `127.0.0.1:${OPENWEBUI_HOST_PORT:-8080}`.
- Data path: `${AGENTIC_ROOT}/openwebui/data`.

Official links:
- Open WebUI docs: https://docs.openwebui.com/
- Official repo: https://github.com/open-webui/open-webui

### Service `openhands`

Simple role:
- Agentic interface focused on task/project execution via LLM.

For beginners:
- OpenWebUI = general conversation.
- OpenHands = action-oriented agent workflows.

Inputs/outputs:
- Host port: `127.0.0.1:${OPENHANDS_HOST_PORT:-3000}`.
- Folders: `${AGENTIC_ROOT}/openhands/{state,logs,workspaces}`.
- `docker.sock` is not mounted (intentional security choice).

Official links:
- OpenHands docs: https://docs.openhands.dev/
- OpenHands CLI mode: https://docs.openhands.dev/openhands/usage/how-to/cli-mode

### Service `comfyui`

Simple role:
- Node-based generative workflow engine/UI (image/video depending on models/plugins).

For beginners:
- Think of it as a visual AI workflow factory (nodes + links + workflows).

Inputs/outputs:
- Main internal service with storage in `${AGENTIC_ROOT}/comfyui/*`.
- Uses GPU (`gpus: all`) with low-priority profile marker in this stack.

Official links:
- ComfyUI docs: https://docs.comfy.org/
- Official repo: https://github.com/Comfy-Org/ComfyUI

### Service `comfyui-loopback`

Simple role:
- Minimal NGINX reverse proxy that publishes ComfyUI on host loopback.

Why it exists:
- Keep ComfyUI internal while safely exposing a local host port.

Inputs/outputs:
- Host port: `127.0.0.1:${COMFYUI_HOST_PORT:-8188}`.

Official links:
- NGINX docs: https://nginx.org/en/docs/
- `nginx-unprivileged` image: https://hub.docker.com/r/nginxinc/nginx-unprivileged

## 6) `obs` Plane (observability)

### Service `prometheus`

Simple role:
- Collects and stores metrics as time series.

For beginners:
- This is the metrics "database of charts".

Inputs/outputs:
- Host port: `127.0.0.1:${PROMETHEUS_HOST_PORT:-19090}`.
- Data path: `${AGENTIC_ROOT}/monitoring/prometheus`.

Official links:
- Prometheus overview: https://prometheus.io/docs/introduction/overview/
- PromQL basics: https://prometheus.io/docs/prometheus/latest/querying/basics/

### Service `grafana`

Simple role:
- Dashboards and visualization for metrics and logs.

For beginners:
- This is the platform "cockpit screen".

Inputs/outputs:
- Host port: `127.0.0.1:${GRAFANA_HOST_PORT:-13000}`.
- Data path: `${AGENTIC_ROOT}/monitoring/grafana`.

Official links:
- Grafana getting started: https://grafana.com/docs/grafana/latest/fundamentals/getting-started/

### Service `loki`

Simple role:
- Centralized log storage.

For beginners:
- Prometheus stores numeric metrics.
- Loki stores log lines.

Inputs/outputs:
- Host port: `127.0.0.1:${LOKI_HOST_PORT:-13100}`.
- Data path: `${AGENTIC_ROOT}/monitoring/loki`.

Official links:
- Loki docs: https://grafana.com/docs/loki/latest/
- Loki architecture: https://grafana.com/docs/loki/latest/fundamentals/architecture/

### Service `promtail`

Simple role:
- Agent that reads logs and forwards them to Loki.

Important note:
- Promtail has an LTS/EOL path in upstream lifecycle, but is still functional here.

Official links:
- Promtail docs: https://grafana.com/docs/loki/latest/send-data/promtail/
- Send data to Loki: https://grafana.com/docs/loki/latest/send-data/

### Service `node-exporter`

Simple role:
- Exposes host system metrics (CPU, RAM, filesystem, etc.) to Prometheus.

Official links:
- Official repo: https://github.com/prometheus/node_exporter

### Service `cadvisor`

Simple role:
- Exposes Docker container resource metrics.

Official links:
- Official repo: https://github.com/google/cadvisor

### Service `dcgm-exporter`

Simple role:
- Exposes NVIDIA GPU metrics to Prometheus.

Official links:
- Official repo: https://github.com/NVIDIA/dcgm-exporter
- NVIDIA DCGM reference docs: https://docs.nvidia.com/datacenter/dcgm/latest/

## 7) `rag` Plane (vector storage)

### Service `qdrant`

Simple role:
- Vector database for semantic retrieval (RAG).

For beginners:
- Stores vector embeddings of documents.
- Enables retrieval of relevant content before generation.

Inputs/outputs:
- No host port published in this stack (internal service).
- Data paths: `${AGENTIC_ROOT}/rag/qdrant` and `${AGENTIC_ROOT}/rag/qdrant-snapshots`.

Official links:
- Qdrant docs: https://qdrant.tech/documentation/
- Official repo: https://github.com/qdrant/qdrant

## 8) `optional` Plane (opt-in modules)

Important:
- These services are not always running.
- They are enabled via Compose profiles + prerequisites/secrets.

### Service `optional-sentinel`

Simple role:
- Minimal sentinel container used to validate optional plane activation.

Official links:
- Alpine image: https://hub.docker.com/_/alpine

### Service `optional-openclaw`

Simple role:
- Optional OpenClaw entrypoint (local webhook/API depending on stack config).

Key point:
- In this repository, it is tightly controlled (secrets, allowlists, sandbox).

Links:
- Internal stack security doc: `docs/security/openclaw-sandbox-egress.md`
- MCP concept reference: https://modelcontextprotocol.io/

### Service `optional-openclaw-sandbox`

Simple role:
- Sandbox execution service used by OpenClaw.

Key point:
- Limits impact and isolates sensitive actions.

Links:
- Internal stack security doc: `docs/security/openclaw-sandbox-egress.md`

### Service `optional-mcp-catalog`

Simple role:
- Optional service around MCP tools/catalog.

For beginners:
- MCP is a standard that connects external tools to AI agents.

Official links:
- MCP introduction: https://modelcontextprotocol.io/
- MCP spec: https://modelcontextprotocol.io/specification/
- MCP SDK docs: https://modelcontextprotocol.io/docs/sdk

### Service `optional-pi-mono`

Simple role:
- Additional optional agent session (same family as `agentic-*`).

Useful links:
- tmux: https://github.com/tmux/tmux

### Service `optional-goose`

Simple role:
- Optional Goose agent in container form.

Official links:
- Goose repo: https://github.com/block/goose
- Goose docs: https://block.github.io/goose/docs/

### Service `optional-portainer`

Simple role:
- Optional container admin UI exposed on loopback only.

Inputs/outputs:
- Host port: `127.0.0.1:${PORTAINER_HOST_PORT:-9001}`.

Official links:
- Portainer docs: https://docs.portainer.io/start/install-ce
- Initial setup: https://docs.portainer.io/start/install-ce/server/setup

## 9) Docker Networks in This Stack

### Network `agentic`

Simple role:
- Main internal network between services.

Key point:
- Some planes define it as `internal: true` to reduce exposure.

### Network `agentic-egress`

Simple role:
- Controlled outbound network for services that need egress.

Key point:
- Complements proxy variables and host controls (profile-dependent).

## 10) How To Read Service State in Practice

Useful commands:

```bash
./agent ps
./agent ls
./agent logs <service>
./agent doctor
```

First checks to run:
- is the service `Up`?
- is healthcheck `healthy`?
- is host port bound to `127.0.0.1`?
- are expected volumes present under `${AGENTIC_ROOT}`?

## 11) Ultra-Short Summary for Beginners

If you are new, remember this sentence:
- "Ollama computes, Ollama-gate controls, OpenWebUI/OpenHands present, Prometheus/Grafana/Loki observe, Qdrant retrieves, and optional modules add capabilities under explicit conditions."

Recommended reading order:
1. `docs/runbooks/introduction.md`
2. `docs/runbooks/profiles.md`
3. `docs/runbooks/first-time-setup.md`
4. this document (`docs/runbooks/services-explained-beginners.en.md`)
5. `docs/runbooks/features-and-agents.md`
