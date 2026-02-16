# Runbook: Implemented Features and Agents

This document explains what is implemented in the current stack, why each component exists, and how components are meant to be used in operations.

The source of truth for service wiring is in:
- `compose/compose.core.yml`
- `compose/compose.agents.yml`
- `compose/compose.ui.yml`
- `compose/compose.obs.yml`
- `compose/compose.rag.yml`
- `compose/compose.optional.yml`

## Platform Features (Cross-Cutting)

### Loopback-only host exposure
- Every published host port is bound on `127.0.0.1`.
- Remote usage is expected through Tailscale + SSH port forwarding, not direct public exposure.

### Baseline container hardening
- `cap_drop: ALL` across services (with narrow `cap_add` exceptions when required).
- `security_opt: no-new-privileges:true`.
- `read_only: true` applied where compatible.
- explicit state/log/workspace mounts instead of writing inside container roots.

### Controlled egress model
- Agent/UI services use proxy environment variables (`HTTP_PROXY`, `HTTPS_PROXY`).
- DNS and proxy services are included in `core`.
- Host-level `DOCKER-USER` enforcement is part of strict profile operations.

### Release traceability and rollback
- `./agent update` captures release snapshots with image digests and effective config.
- `./agent rollback all <release_id>` restores a prior recorded release deterministically.

### Compliance diagnostics
- `./agent doctor` validates loopback binds, hardening posture, mounts, healthchecks, and release traceability requirements.

## Core Stack (`./agent up core`)

### `ollama`
- Role: shared local model inference backend.
- Access path:
  - host: `127.0.0.1:11434`
  - internal: `ollama:11434`
- Persistence:
  - `${AGENTIC_ROOT}/ollama/models`
- Why it exists:
  - provides a single model serving endpoint for agents and UIs.

### `ollama-gate`
- Role: request gate in front of Ollama.
- Access path:
  - internal only: `ollama-gate:11435`
- Persistence:
  - `${AGENTIC_ROOT}/gate/state`
  - `${AGENTIC_ROOT}/gate/logs`
- Why it exists:
  - centralizes concurrency/queueing behavior and gate-level logging for model calls.

### `unbound`
- Role: DNS resolver used by the stack egress path.
- Configuration:
  - `${AGENTIC_ROOT}/dns/unbound.conf`
- Why it exists:
  - provides controlled DNS behavior for network policy consistency.

### `egress-proxy` (Squid)
- Role: HTTP/HTTPS egress proxy for service outbound requests.
- Configuration and logs:
  - `${AGENTIC_ROOT}/proxy/config/squid.conf`
  - `${AGENTIC_ROOT}/proxy/allowlist.txt`
  - `${AGENTIC_ROOT}/proxy/logs`
- Why it exists:
  - creates a central enforcement point for outbound destinations.

### `toolbox`
- Role: debug/inspection container on stack networks.
- Why it exists:
  - gives operators a controlled diagnostic shell for connectivity checks without weakening app containers.

## Agent Stack (`./agent up agents`)

The baseline agent services are tmux-backed CLI environments in hardened containers.  
Interactive entrypoint is through `./agent <tool> [project]`.

### `agentic-claude`
- `./agent claude <project>`
- Role: Claude-oriented agent workspace runtime.
- Persistence:
  - `${AGENTIC_ROOT}/claude/state`
  - `${AGENTIC_ROOT}/claude/logs`
  - `${AGENTIC_ROOT}/claude/workspaces`
- Why it exists:
  - provides isolated state/log/workspace paths for Claude workflows.

### `agentic-codex`
- `./agent codex <project>`
- Role: Codex-oriented agent workspace runtime.
- Persistence:
  - `${AGENTIC_ROOT}/codex/state`
  - `${AGENTIC_ROOT}/codex/logs`
  - `${AGENTIC_ROOT}/codex/workspaces`
- Why it exists:
  - same controlled runtime model as other agents, specialized for Codex usage.

### `agentic-opencode`
- `./agent opencode <project>`
- Role: OpenCode-oriented agent workspace runtime.
- Persistence:
  - `${AGENTIC_ROOT}/opencode/state`
  - `${AGENTIC_ROOT}/opencode/logs`
  - `${AGENTIC_ROOT}/opencode/workspaces`
- Why it exists:
  - allows running multiple agent tools with a consistent operational contract.

### Shared agent paths
- `${AGENTIC_ROOT}/shared-ro` mounted read-only into agent containers.
- `${AGENTIC_ROOT}/shared-rw` mounted read-write into agent containers.
- Why they exist:
  - simplify controlled file exchange between isolated agent runtimes.

## UI Stack (`./agent up ui`)

### `openwebui`
- Host URL: `http://127.0.0.1:${OPENWEBUI_HOST_PORT:-8080}`
- Role: browser UI for interacting with model-backed chat workflows.
- Backend model API target:
  - `http://ollama-gate:11435/v1`
- Persistence:
  - `${AGENTIC_ROOT}/openwebui/data`

### `openhands`
- Host URL: `http://127.0.0.1:${OPENHANDS_HOST_PORT:-3000}`
- Role: OpenHands server/UI configured in CLI runtime mode (no Docker socket mount).
- Persistence:
  - `${AGENTIC_ROOT}/openhands/state`
  - `${AGENTIC_ROOT}/openhands/logs`
  - `${AGENTIC_ROOT}/openhands/workspaces`
- Why it exists:
  - provides UI-driven agentic workflows while preserving the no-`docker.sock` policy.

### `comfyui`
- Internal service endpoint: `comfyui:8188`
- Role: GPU-enabled visual workflow runtime.
- Persistence:
  - `${AGENTIC_ROOT}/comfyui/models`
  - `${AGENTIC_ROOT}/comfyui/input`
  - `${AGENTIC_ROOT}/comfyui/output`
  - `${AGENTIC_ROOT}/comfyui/user`

### `comfyui-loopback`
- Host URL: `http://127.0.0.1:${COMFYUI_HOST_PORT:-8188}`
- Role: loopback-only reverse proxy exposing ComfyUI safely to host localhost.
- Why it exists:
  - keeps host exposure local while separating frontend bind from internal service.

## Observability Stack (`./agent up obs`)

### `prometheus`
- Host URL: `http://127.0.0.1:${PROMETHEUS_HOST_PORT:-19090}`
- Role: metrics scrape and time-series storage.
- Persistence:
  - `${AGENTIC_ROOT}/monitoring/prometheus`
  - config from `${AGENTIC_ROOT}/monitoring/config/prometheus.yml`

### `grafana`
- Host URL: `http://127.0.0.1:${GRAFANA_HOST_PORT:-13000}`
- Role: dashboards and operational visualization.
- Persistence:
  - `${AGENTIC_ROOT}/monitoring/grafana`

### `loki`
- Host URL: `http://127.0.0.1:${LOKI_HOST_PORT:-13100}`
- Role: centralized log storage/query backend.
- Persistence:
  - `${AGENTIC_ROOT}/monitoring/loki`
  - config from `${AGENTIC_ROOT}/monitoring/config/loki-config.yml`

### `promtail`
- Internal shipper to Loki.
- Role: log collection agent for Docker/container and host logs.
- Persistence:
  - `${AGENTIC_ROOT}/monitoring/promtail/positions`
- Why it exists:
  - forwards logs to Loki with restart-safe file positions.

### `node-exporter`
- Role: host system metrics exporter.
- Why it exists:
  - provides CPU/memory/disk/network telemetry to Prometheus.

### `cadvisor`
- Role: container metrics exporter.
- Why it exists:
  - provides per-container runtime statistics to Prometheus.

### `dcgm-exporter`
- Role: NVIDIA GPU metrics exporter.
- Why it exists:
  - adds GPU observability for model/UI workloads that use accelerators.

## RAG Stack (`./agent up rag`)

### `qdrant`
- Role: vector database backend for retrieval workloads.
- Access path:
  - internal only (not host-published in current baseline)
- Persistence:
  - `${AGENTIC_ROOT}/rag/qdrant`
  - `${AGENTIC_ROOT}/rag/qdrant-snapshots`
- Why it exists:
  - persistent vector index storage for optional or future retrieval features.

## Optional Stack (`./agent up optional`)

Optional modules are disabled unless `AGENTIC_OPTIONAL_MODULES` is set explicitly.
See `docs/runbooks/optional-modules.md` for gating and security details.

Implemented optional services:
- `optional-openclaw` (`openclaw`)
- `optional-mcp-catalog` (`mcp`)
- `optional-pi-mono` (`pi-mono`)
- `optional-goose` (`goose`)
- `optional-portainer` (`portainer`)

## Agent CLI Features (`./agent`)

`./agent` is the operational wrapper around Compose and deployment scripts.

Key implemented capabilities:
- stack lifecycle:
  - `agent up <core|agents|ui|obs|rag|optional>`
  - `agent down <core|agents|ui|obs|rag|optional>`
- interactive sessions:
  - `agent claude <project>`
  - `agent codex <project>`
  - `agent opencode <project>`
- operational controls:
  - `agent logs <service>`
  - `agent ls`
  - `agent stop <tool>`
- compliance and tests:
  - `agent doctor [--fix-net]`
  - `agent test <A..K|all>`
- update and rollback:
  - `agent update`
  - `agent rollback all <release_id>`
  - `agent rollback host-net <backup_id>`
  - `agent rollback ollama-link <backup_id|latest>`
- profile and model store utilities:
  - `agent profile`
  - `agent ollama-link`
  - `agent ollama-preload ...`
  - `agent ollama-models <rw|ro>`

## Notes for Operations

- Start minimal (`core` then `agents`/`ui`) and activate `obs`, `rag`, or `optional` only as needed.
- Keep strict acceptance checks in `strict-prod`.
- Use release snapshots and rollback rather than ad hoc image pinning changes on running hosts.
