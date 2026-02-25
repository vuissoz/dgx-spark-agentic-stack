# Runbook: Implemented Features and Agents

This document explains what is implemented in the current stack, why each component exists, and how components are meant to be used in operations.

The source of truth for service wiring is in:
- `compose/compose.core.yml`
- `compose/compose.agents.yml`
- `compose/compose.ui.yml`
- `compose/compose.obs.yml`
- `compose/compose.rag.yml`
- `compose/compose.optional.yml`

For configuration variables, accepted values, storage locations, and secrets handling:
- `docs/runbooks/configuration-expliquee-debutants.md`
- `docs/runbooks/configuration-explained-beginners.en.md`

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

### Incremental backups (Time Machine)
- `./agent backup run` creates a timestamped incremental snapshot of runtime persistence and non-secret config.
- `./agent backup list` reports available snapshots with retention policy and metadata.
- `./agent backup restore <snapshot_id> [--yes]` restores a selected snapshot (destructive opt-in).
- Backup snapshots explicitly exclude `${AGENTIC_ROOT}/secrets/**` and private key material patterns.

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
  - `${AGENTIC_ROOT}/gate/config`
  - `${AGENTIC_ROOT}/gate/state`
  - `${AGENTIC_ROOT}/gate/logs`
- Why it exists:
  - centralizes concurrency/queueing behavior and gate-level logging for model calls.
  - resolves model routing policy (`model -> backend`) from `${AGENTIC_ROOT}/gate/config/model_routes.yml`.
  - supports external provider backends (`openai`, `openrouter`) with the same client API (`/v1/*`).
  - logs backend/provider audit fields (`backend`, `provider`) for every `/v1/*` request.
  - reads provider secrets from `${AGENTIC_ROOT}/secrets/runtime/*.api_key` (never from git).

### `gate-mcp`
- Role: internal MCP gateway for runtime visibility/control around `ollama-gate`.
- Access path:
  - internal only: `gate-mcp:8123`
- Persistence:
  - `${AGENTIC_ROOT}/gate/mcp/state`
  - `${AGENTIC_ROOT}/gate/mcp/logs`
- Why it exists:
  - exposes local MCP tools for agents:
    - `gate.current_model`
    - `gate.quota_remaining`
    - `gate.switch_model`
  - enforces local token auth with `${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token`.
  - keeps audit traces for MCP calls without exposing provider secrets.

### `trtllm` (optional `trt` profile)
- Role: internal TRT-LLM backend used for NVFP4-routed models.
- Activation:
  - `COMPOSE_PROFILES=trt ./agent up core`
- Access path:
  - internal-only on dedicated `agentic-llm` network (no host-published ports).
  - reachable from `ollama-gate`; not reachable from generic internal tooling (`toolbox`).
- Persistence:
  - `${AGENTIC_ROOT}/trtllm/models`
  - `${AGENTIC_ROOT}/trtllm/state`
  - `${AGENTIC_ROOT}/trtllm/logs`
- Why it exists:
  - enables backend separation where standard models stay on `ollama` while NVFP4 model patterns route to `trtllm`.

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

Primary CLI contract per baseline service:
- `agentic-claude` -> `claude`
- `agentic-codex` -> `codex`
- `agentic-opencode` -> `opencode`
- `agentic-vibestral` -> `vibe`

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

### `agentic-vibestral`
- `./agent vibestral <project>`
- Role: Vibestral-oriented agent workspace runtime.
- Persistence:
  - `${AGENTIC_ROOT}/vibestral/state`
  - `${AGENTIC_ROOT}/vibestral/logs`
  - `${AGENTIC_ROOT}/vibestral/workspaces`
- Why it exists:
  - extends the same hardened, persistent agent runtime model to a fourth first-class agent tool.

### Shared agent paths
- `${AGENTIC_ROOT}/shared-ro` mounted read-only into agent containers.
- `${AGENTIC_ROOT}/shared-rw` mounted read-write into agent containers.
- Why they exist:
  - simplify controlled file exchange between isolated agent runtimes.

### Agent MCP wiring (D7)
- `GATE_MCP_URL=http://gate-mcp:8123`
- `GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token`
- Why it exists:
  - allows agents to consume D7 runtime MCP tools over the internal network only.

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
- Host telemetry mounts (configurable):
  - `PROMTAIL_DOCKER_CONTAINERS_HOST_PATH` -> `/var/lib/docker/containers` in-container
  - `PROMTAIL_HOST_LOG_PATH` -> `/var/log` in-container
- Why it exists:
  - forwards logs to Loki with restart-safe file positions.
  - ingests proxy access logs from `${AGENTIC_ROOT}/proxy/logs/access.log*` to provide egress ground truth.

### `node-exporter`
- Role: host system metrics exporter.
- Host telemetry mount (configurable):
  - `NODE_EXPORTER_HOST_ROOT_PATH` -> `/host` in-container
- Why it exists:
  - provides CPU/memory/disk/network telemetry to Prometheus.

### `cadvisor`
- Role: container metrics exporter.
- Host telemetry mounts (configurable):
  - `CADVISOR_HOST_ROOT_PATH` -> `/rootfs`
  - `CADVISOR_DOCKER_LIB_HOST_PATH` -> `/var/lib/docker`
  - `CADVISOR_SYS_HOST_PATH` -> `/sys`
  - `CADVISOR_DEV_DISK_HOST_PATH` -> `/dev/disk`
- Why it exists:
  - provides per-container runtime statistics to Prometheus.

### `dcgm-exporter`
- Role: NVIDIA GPU metrics exporter.
- Why it exists:
  - adds GPU observability for model/UI workloads that use accelerators.

### Triage Runbook
- See `docs/runbooks/observability-triage.md` for high-signal incident queries and alert baselines across app, egress, and runtime layers.

## RAG Stack (`./agent up rag`)

### `qdrant`
- Role: vector database backend for retrieval workloads.
- Access path:
  - internal only (not host-published in current baseline)
- Persistence:
  - `${AGENTIC_ROOT}/rag/qdrant`
  - `${AGENTIC_ROOT}/rag/qdrant-snapshots`
- Why it exists:
  - persistent vector index storage for hybrid retrieval features.

### `rag-retriever`
- Role: internal retrieval orchestrator (dense + lexical + fusion).
- Access path:
  - internal-only: `rag-retriever:7111`
- Persistence:
  - `${AGENTIC_ROOT}/rag/retriever/state`
  - `${AGENTIC_ROOT}/rag/retriever/logs`
- Why it exists:
  - executes dense retrieval through `qdrant`,
  - executes lexical retrieval through `opensearch` when profile `rag-lexical` is enabled,
  - applies fusion (`rrf`) and emits retrieval audit events.

### `rag-worker`
- Role: async indexing worker for retrieval pipelines.
- Access path:
  - internal-only: `rag-worker:7112`
- Persistence:
  - `${AGENTIC_ROOT}/rag/worker/state`
  - `${AGENTIC_ROOT}/rag/worker/logs`
- Why it exists:
  - processes indexing tasks (`/v1/index`) against local corpus docs,
  - keeps retrieval/indexing flow operational without exposing RAG internals on host ports.

### `opensearch` (optional `rag-lexical` profile)
- Role: lexical BM25 backend for hybrid retrieval.
- Activation:
  - `COMPOSE_PROFILES=rag-lexical ./agent up rag`
- Access path:
  - internal-only: `opensearch:9200`
- Persistence:
  - `${AGENTIC_ROOT}/rag/opensearch`
  - `${AGENTIC_ROOT}/rag/opensearch-logs`
- Why it exists:
  - provides lexical retrieval signals fused with dense results in `rag-retriever`.

## Optional Stack (`./agent up optional`)

Optional modules are disabled unless `AGENTIC_OPTIONAL_MODULES` is set explicitly.
See `docs/runbooks/optional-modules.md` for gating and security details.

Implemented optional services:
- `optional-openclaw` (`openclaw`)
- `optional-openclaw-sandbox` (OpenClaw isolated tool runtime)
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
  - `agent vibestral <project>`
- operational controls:
  - `agent logs <service>`
  - `agent ls`
  - `agent stop <tool>`
- compliance and tests:
  - `agent doctor [--fix-net]`
  - `agent test <A..L|V|all> [--skip-d5-tests]`
- update and rollback:
  - `agent update`
  - `agent rollback all <release_id>`
  - `agent rollback host-net <backup_id>`
  - `agent rollback ollama-link <backup_id|latest>`
- vm provisioning:
  - `agent vm create [--name ... --cpus ... --memory ... --disk ... --image ... --workspace-path ... --reuse-existing --mount-repo|--no-mount-repo --require-gpu --skip-bootstrap --dry-run]`
  - `agent vm test [--name ... --workspace-path ... --test-selectors ... --require-gpu|--allow-no-gpu --skip-d5-tests --dry-run]`
  - `agent vm cleanup [--name ... --yes --dry-run]`
- profile and model store utilities:
  - `agent profile`
  - `agent onboard [runtime flags...] [--openwebui-admin-email ... --openwebui-admin-password ... --openhands-llm-model ... --allowlist-domains ... --optional-modules ... --output ... --non-interactive --require-complete]`
  - `agent ollama-link`
  - `agent ollama-preload ...`
  - `agent ollama-models <rw|ro>`

## Notes for Operations

- Start minimal (`core` then `agents`/`ui`) and activate `obs`, `rag`, or `optional` only as needed.
- Keep strict acceptance checks in `strict-prod`.
- Use release snapshots and rollback rather than ad hoc image pinning changes on running hosts.
