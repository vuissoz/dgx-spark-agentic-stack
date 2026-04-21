# DGX Spark Agentic Stack

This repository provides a containerized agentic services stack for DGX Spark, with:
- local-only exposure (`127.0.0.1` binds),
- egress control (proxy + DOCKER-USER in `strict-prod`),
- baseline hardening (`read_only`, `cap_drop: ALL`, `no-new-privileges`),
- release snapshots + rollback,
- orchestration through a single command: `./agent`.

Current repo state: the primary day-to-day operating mode is `rootless-dev`. `strict-prod` remains the production-like validation path and the CDC acceptance profile.

## Compose Stacks

Compose files are located in `compose/`:
- `compose/compose.core.yml`: `ollama`, `ollama-gate`, `gate-mcp`, `openclaw`, `openclaw-gateway`, `openclaw-sandbox`, `openclaw-relay`, `trtllm` (`trt` profile), `unbound`, `egress-proxy`, `toolbox`
- `compose/compose.agents.yml`: `agentic-claude`, `agentic-codex`, `agentic-opencode`, `agentic-vibestral`, `agentic-hermes`
- `compose/compose.ui.yml`: `optional-forgejo`, `optional-forgejo-loopback`, `openwebui`, `openhands`, `comfyui`
- `compose/compose.obs.yml`: `prometheus`, `grafana`, `loki`, exporters
- `compose/compose.rag.yml`: `qdrant`, `rag-retriever`, `rag-worker`, `opensearch` (`rag-lexical` profile)
- `compose/compose.optional.yml`: `optional-sentinel`, `optional-mcp-catalog`, `optional-pi-mono`, `optional-goose`, `optional-portainer`

## Execution Profiles

The profile is controlled by `AGENTIC_PROFILE`:
- `strict-prod` (default): runtime under `/srv/agentic`, host `DOCKER-USER` checks enabled.
- `rootless-dev`: runtime under `${HOME}/.local/share/agentic`, root-only host checks degraded.

In practice, start in `rootless-dev` unless you are explicitly running a prod-like validation cycle.

Check with:

```bash
./agent profile
```

Optional TRT-LLM backend activation (internal-only):

```bash
./agent onboard --compose-profiles trt --trtllm-models https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8
source .runtime/env.generated.sh
./agent up core
```

In interactive mode, `./agent onboard` now also asks explicitly whether to enable TRT when `COMPOSE_PROFILES` does not already contain `trt`, then records `TRTLLM_MODELS`.
The `trtllm` service now attempts to launch a real NVIDIA TRT-LLM backend whenever `${AGENTIC_ROOT}/secrets/runtime/huggingface.token` is non-empty; otherwise it intentionally falls back to `mock` mode to preserve deterministic tests.
By default (`TRTLLM_NATIVE_MODEL_POLICY=auto`), the native runtime exposes a single TRT model controlled by `TRTLLM_MODELS`, with `NVIDIA-Nemotron-3-Nano-30B-A3B-FP8` as the default value.
A hardened DGX Spark mode now exists: `TRTLLM_NATIVE_MODEL_POLICY=strict-nvfp4-local-only` accepts exactly one exposed alias at a time (`TRTLLM_MODELS`) and forces the actual load target to a single local directory `TRTLLM_NVFP4_LOCAL_MODEL_DIR`, with no silent fallback.
For UIs such as OpenWebUI, the TRT catalog also derives a readable alias from the actually configured TRT model. With the current Nano default, that becomes `trtllm/nvidia-nemotron-3-nano-30b-a3b-fp8`, while the Hugging Face URL remains the canonical identifier for direct calls and tests.
The `OpenWebUI -> ollama-gate -> trtllm` path now supports real SSE/chunked streaming for `/v1/chat/completions`: the gate forwards TRT chunks as they arrive instead of buffering the full response.
On that default Nano path, the runtime also bounds `TRTLLM_NATIVE_MAX_NUM_TOKENS=4096`, `TRTLLM_NATIVE_MAX_SEQ_LEN=32768`, and leaves `TRTLLM_NATIVE_ENABLE_CUDA_GRAPH=false` to avoid DGX Spark warm-ups getting stuck at `max_seq_len=262144`.
When `COMPOSE_PROFILES` includes `trt` and `${AGENTIC_ROOT}/secrets/runtime/huggingface.token` is non-empty, `./agent up core` now prefetches only the Hugging Face cache for the default exposed TRT model `NVIDIA-Nemotron-3-Nano-30B-A3B-FP8`. The strict local directory is never bootstrapped automatically; it stays opt-in through `./agent trtllm prepare`.
Example activation:

```bash
export TRTLLM_NATIVE_MODEL_POLICY=strict-nvfp4-local-only
export TRTLLM_MODELS=https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8
export TRTLLM_NVFP4_LOCAL_MODEL_DIR=/srv/agentic/trtllm/models/trtllm-model
./agent up core
```

If the local NVFP4 directory is missing, `/healthz` returns an explicit error instead of silently falling back to `mock`.
Local bootstrap progress is logged to `${AGENTIC_ROOT}/trtllm/logs/nvfp4-model-prepare.log`.
Operator TRT commands:

```bash
./agent trtllm status
./agent trtllm prepare
./agent trtllm start
./agent trtllm stop
```

Only one TRT model is exposed by the stack at a time on DGX Spark.
On the first native startup, the backend can remain in `status=starting` for several minutes while it downloads and warms the Hugging Face artifacts; until `native_ready=true`, gate requests receive an explicit `503` instead of silently falling back to a mock.
Model-to-backend routing remains centralized in `ollama-gate` via `${AGENTIC_ROOT}/gate/config/model_routes.yml`.
The default local model is controlled by `AGENTIC_DEFAULT_MODEL` (fallback `nemotron-cascade-2:30b`) and reused by Ollama preload.
The stack now emits an explicit warning if you choose `qwen3.5:35b`: as of March 26, 2026, local Codex/OpenHands runs in this repo have already shown pseudo tool tags instead of real tool calls, even though Ollama upstream advertises the model with `tools` support. The model is no longer blocked, because this is treated as a stack integration bug to fix rather than a model capability contract.
Context window size is controlled by `AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW` (default `50909`) and propagated to `OLLAMA_CONTEXT_LENGTH`.
For Goose (`optional-goose`), the client-side context limit is controlled separately by `AGENTIC_GOOSE_CONTEXT_LIMIT` (default: `${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW}`) and propagated to `GOOSE_CONTEXT_LIMIT`.
The stack also publishes a shared compaction policy derived from the effective context budget: `AGENTIC_CONTEXT_BUDGET_TOKENS`, `AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS` (default policy `75%`) and `AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS` (default policy `90%`). `codex` receives the soft threshold as `auto_compact_token_limit`, while `goose` and `openhands` receive the same thresholds as runtime env hints.

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
- `{claude,codex,opencode,vibestral,hermes}/{state,logs,workspaces}/`
- `openclaw/{config/{immutable,overlay},state,logs,relay/{state,logs},sandbox/state,workspaces}/`
- `optional/{git,mcp,pi-mono,goose,portainer}/...`
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

Agent services (`agentic-claude`, `agentic-codex`, `agentic-opencode`, `agentic-vibestral`, `agentic-hermes`) share a common runtime-configurable base image.

By default, `deployments/images/agent-cli-base/Dockerfile` builds a CUDA-based (NVIDIA) development image with a multi-language toolchain (C/C++, Python, Node, Go, Rust).

This shared image also installs these agent CLIs: `codex`, `claude`, `opencode`, `pi`, `vibe`, `openhands`, `openclaw`, `hermes`.
- default mode: `AGENT_CLI_INSTALL_MODE=best-effort` (explicit wrappers if an install fails),
- strict mode: `AGENT_CLI_INSTALL_MODE=required` (build fails when a CLI install is missing).

Build traceability:
- `/etc/agentic/cli-install-status.tsv`
- `/etc/agentic/<cli>-real-path`

Supported variables:
- `AGENTIC_AGENT_BASE_IMAGE` (default: `agentic/agent-cli-base:local`)
- `AGENTIC_AGENT_BASE_BUILD_CONTEXT` (default: repository root)
- `AGENTIC_AGENT_BASE_DOCKERFILE` (default: `deployments/images/agent-cli-base/Dockerfile`)
- `AGENTIC_AGENT_CLI_INSTALL_MODE` (`best-effort` by default, `required` for strict builds)
- `AGENTIC_AGENT_NO_NEW_PRIVILEGES` (`true` by default; set to `false` to enable in-container sudo mode for agent services)
- `AGENTIC_CODEX_CLI_NPM_SPEC`, `AGENTIC_CLAUDE_CODE_NPM_SPEC`, `AGENTIC_OPENCODE_NPM_SPEC`, `AGENTIC_PI_CODING_AGENT_NPM_SPEC`
- `AGENTIC_OPENHANDS_INSTALL_SCRIPT`, `AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT`, `AGENTIC_OPENCLAW_INSTALL_VERSION`, `AGENTIC_VIBE_INSTALL_SCRIPT`
- `AGENTIC_HERMES_AGENT_GIT_URL`, `AGENTIC_HERMES_AGENT_GIT_REF`, `AGENTIC_HERMES_AGENT_GIT_SHA`, `AGENTIC_HERMES_PIP_EXTRAS`

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
- Multipass (`multipass`) for VM commands (`agent vm create`, `agent vm test`, `agent vm cleanup`)
- NVIDIA Container Toolkit (for GPU services)
- `iptables` available (in `strict-prod` for `DOCKER-USER`)
- `acl` / `setfacl` recommended in `rootless-dev` (Squid log ACLs)

Quick prerequisite validation:

```bash
./agent prereqs
```

GPU note: if your environment uses a specific CDI/driver path, you can override the smoke-test image:
- `AGENTIC_NVIDIA_SMOKE_IMAGE` (default: `nvidia/cuda:12.2.0-base-ubuntu22.04`)

## Quick Start

### `strict-prod`

```bash
export AGENTIC_PROFILE=strict-prod
sudo ./deployments/bootstrap/init_fs.sh
sudo ./agent up core
sudo ./agent up agents,ui,obs,rag
sudo ./agent doctor
```

Equivalent one-shot command:

```bash
sudo -E ./agent first-up
```

Cleanup for `strict-prod` runtime (back to a "fresh" state):

```bash
sudo ./agent strict-prod cleanup
# or non-interactive:
sudo ./agent strict-prod cleanup --yes --no-backup
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

Equivalent one-shot command:

```bash
./agent first-up
```

In `rootless-dev`, `first-up` does not require a prior `agent update`. If the first
bootstrap release does not have `latest-resolution.json` yet, `doctor` emits a
non-blocking warning and lets the first startup complete; run `./agent update` after
that first success to pin auditable digests/versions.

Cleanup for `rootless-dev` runtime (back to a "fresh" state):

```bash
./agent rootless-dev cleanup
# or non-interactive:
./agent rootless-dev cleanup --yes --no-backup
```

## Remote Access (Tailscale + SSH tunnel)

Services are bound on `127.0.0.1` on the host.
Consequence: from another machine (even on the same Tailscale network), `http://<tailscale-host-ip>:8080` will not work directly.

The expected access mode is an SSH tunnel from client to DGX host.
The repo now ships a stack-aware generator so tunnel commands stay aligned with the actual host-port contract:

```bash
./agent tunnel list --all
./agent tunnel check --all
```

Generate a client artifact for the target platform:

Linux or macOS:

```bash
./agent tunnel generate linux --enabled --ssh-target <user>@<tailscale-hostname-or-ip> --output ./agentic-tunnel.sh
./agentic-tunnel.sh
```

On macOS, use `macos` instead of `linux`; the generated artifact stays a POSIX shell script.

Windows PowerShell:

```powershell
./agent tunnel generate windows --enabled --ssh-target <user>@<tailscale-hostname-or-ip> --output .\agentic-tunnel.ps1
.\agentic-tunnel.ps1
```

If you want all known loopback-published surfaces rather than only the currently reachable ones, replace `--enabled` with `--all`.
`./agent tunnel list --all` is the single source of truth for the tunnelable stack surfaces and resolved ports.

On first `obs` startup, Grafana auto-provisions the
`DGX Spark Agentic Activity Overview` dashboard (UID `dgx-spark-activity`) and
the `Prometheus` + `Loki` datasources.
When `core` is also enabled, this dashboard now includes `OpenClaw TCP Forwarder Health`
and `OpenClaw TCP Forwarder Traffic`, backed by the internal scrape target
`openclaw-gateway:9114/metrics` for the loopback-publishing gateway forwarder.

Notes:
- tunnel only the ports you need; the generator accepts repeated `--surface <id>` selectors;
- host ports are configurable via environment variables (`*_HOST_PORT`) and reflected by `agent tunnel list`;
- `qdrant` is not published on a host port in the current configuration;
- `rag-retriever` (`7111`) and `rag-worker` (`7112`) are never host-published;
- `opensearch` (`rag-lexical`) remains internal-only (no host-published port);
- `openclaw` only publishes local webhook ingress (`127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`), never `0.0.0.0`.
- `openclaw-gateway` only publishes the upstream OpenClaw Web UI/WS on loopback (`127.0.0.1:${OPENCLAW_GATEWAY_HOST_PORT:-18789}`), never `0.0.0.0`.
- the OpenClaw TCP forwarder metrics endpoint is internal-only (`openclaw-gateway:9114/metrics`) and is not host-published.

Windows PowerShell example (Loki API):

```powershell
$url = "http://127.0.0.1:13100/loki/api/v1/query_range?query=%7Bjob%3D%22egress-proxy%22%7D&limit=20"
(Invoke-RestMethod -Uri $url -Method Get).data.result
```

Loki notes:
- `http://127.0.0.1:13100/` may return `404 page not found` (expected).
- Use Grafana (`http://127.0.0.1:13000`) for UI, and Loki (`13100`) for API access.

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

Yes. iPhone does not have a generic shell-script path, so the repo generates an OpenSSH-style config snippet instead:

```bash
./agent tunnel generate iphone --enabled --ssh-target <user>@<tailscale-hostname-or-ip> --name dgx-spark --output ./dgx-spark-iphone.conf
```

Import or transcribe that snippet into an iPhone SSH client that supports local forwarding (for example Blink or a manual Termius host entry), connect, then open `http://127.0.0.1:<port>` locally on the phone.

## `agent` Commands

Supported commands:

```text
agent [strict-prod|rootless-dev] <command ...>
agent profile
agent first-up [--env-file <path>] [--no-env] [--dry-run]
agent up <core|agents|ui|obs|rag|optional>
agent down <core|agents|ui|obs|rag|optional>
agent stack <start|stop> <core|agents|ui|obs|rag|optional|all>
agent <claude|codex|opencode|vibestral|hermes|openclaw|pi-mono|goose> [project]
agent openclaw init [project]
agent ls
agent ps
agent llm mode [local|hybrid|remote]
agent llm backend [ollama|trtllm|both|remote]
agent llm test-mode [on|off]
agent rag index [--docs-dir <path>] [--wait|--sync|--no-wait] [--timeout-sec <seconds>] [--json]
agent rag task <task_id> [--json]
agent rag bootstrap-lexical [--json]
agent rag config [--json]
agent trtllm [status|prepare|start|stop]
agent comfyui flux-1-dev [--download] [--hf-token-file <path>] [--no-egress-check] [--dry-run]
agent logs <service>
agent stop <tool>
agent stop service <service...>
agent stop container <container...>
agent start service <service...>
agent start container <container...>
agent backup <run|list|restore <snapshot_id> [--yes]>
agent forget <target> [--yes] [--no-backup]
agent cleanup [--yes] [--backup|--no-backup] [--purge-models]
agent strict-prod cleanup [--yes] [--backup|--no-backup]
agent rootless-dev cleanup [--yes] [--backup|--no-backup]
agent net apply
agent ollama unload <model>
agent ollama-link
agent ollama-drift watch [--ack-baseline] [--no-beads] [--issue-id <id>] [--state-dir <path>] [--sources-dir <path>] [--sources <csv>] [--timeout-sec <int>] [--quiet]
agent ollama-drift schedule [--disable] [--dry-run] [--on-calendar <expr>] [--cron <expr>] [--force-cron]
agent ollama-preload [--generate-model <model>] [--embed-model <model>] [--budget-gb <int>] [--no-lock-ro]
agent ollama-models [status|rw|ro]
agent sudo-mode [status|on|off]
agent update
agent rollback all <release_id>
agent rollback host-net <backup_id>
agent rollback ollama-link <backup_id|latest>
agent repo-e2e [--agents <csv>] [--repo <name>] [--clone-url <url>] [--artifacts-dir <path>] [--attempts <int>] [--reset-agent-branches] [--dry-run]
agent onboard [--profile ... --root ... --compose-project ... --network ... --egress-network ... --ollama-models-dir ... --default-model ... --grafana-admin-user ... --grafana-admin-password ... --openwebui-allow-model-pull <true|false> --huggingface-token ... --openclaw-init-project ... --telegram-bot-token ... --discord-bot-token ... --slack-bot-token ... --slack-app-token ... --slack-signing-secret ... --limits-default-cpus ... --limits-default-mem ... --limits-core-cpus ... --limits-core-mem ... --limits-agents-cpus ... --limits-agents-mem ... --limits-ui-cpus ... --limits-ui-mem ... --limits-obs-cpus ... --limits-obs-mem ... --limits-rag-cpus ... --limits-rag-mem ... --limits-optional-cpus ... --limits-optional-mem ... --output ... --non-interactive]
agent vm create [--name ... --cpus ... --memory ... --disk ... --image ... --workspace-path ... --reuse-existing --mount-repo|--no-mount-repo --require-gpu --skip-bootstrap --dry-run]
agent vm test [--name ... --workspace-path ... --test-selectors ... --require-gpu|--allow-no-gpu --skip-d5-tests --dry-run]
agent vm cleanup [--name ... --yes --dry-run]
agent test <A|B|C|D|E|F|G|H|I|J|K|L|V|all> [--skip-d5-tests]
agent doctor [--fix-net] [--check-tool-stream-e2e]
```

### RAG Operator Flow

The default corpus lives in `${AGENTIC_ROOT}/rag/docs` and is indexed through the internal worker, with no host-published RAG ports:

```bash
./agent up rag
./agent rag index --wait
```

For lexical OpenSearch mode, enable the profile and reindex:

```bash
COMPOSE_PROFILES=rag-lexical ./agent up rag
./agent rag bootstrap-lexical
./agent rag index --wait
```

`RAG_LEXICAL_BACKEND` automatically becomes `opensearch` when `COMPOSE_PROFILES` contains `rag-lexical`, unless explicitly overridden. The reranker stays disabled by default; enable it with `RAG_RERANK_ENABLED=1` (local `lexical` backend) when you want one extra ranking pass after `rrf` fusion.

Examples:

```bash
./agent up core
./agent up agents,ui
./agent first-up
./agent codex my-project
./agent logs ollama
./agent stop codex
./agent backup run
./agent backup list
./agent sudo-mode on
./agent update
./agent rollback all <release_id>
./agent repo-e2e --dry-run
./agent repo-e2e --attempts 5 --reset-agent-branches
./agent test all --skip-d5-tests
./agent vm test --name agentic-strict-prod --allow-no-gpu --skip-d5-tests
./agent comfyui flux-1-dev --no-egress-check
```

Notes:
- `agent stop` and `agent start` handle `claude|codex|opencode|vibestral|hermes|openclaw|pi-mono|goose|openwebui|openhands|comfyui` targets.
- `agent stop/start openclaw` manages the whole OpenClaw control/execution bundle; `agent stop/start comfyui` manages both `comfyui` and `comfyui-loopback`.
- `agent trtllm stop` cleanly stops only the `trtllm` service; `agent trtllm start` brings it back and waits for its healthcheck.
- `agent ls` now reads target state from `docker ps -a`, so stopped targets show `exited` or `mixed` instead of collapsing to `down`; `agent status` lists every project container with its exact state and health string.
- `agent <tool> [project]` attaches to a persistent session: `claude|codex|opencode|vibestral|hermes|pi-mono` use tmux (`Ctrl-b d` to detach), `goose` launches the Goose CLI directly in `/workspace/<project>` (no tmux in upstream image), and `openclaw` opens an operator shell in the core `openclaw` service with loopback API, Web UI (`18789`), and Gateway WS reminders.
- `agent openclaw init [project]` is the stack-managed OpenClaw onboarding/repair path: it repairs the default workspace back under `/workspace/...`, starts the core bundle if needed, applies the safe local bootstrap, then prints the exact provider/channel next steps. Without an argument it uses `AGENTIC_OPENCLAW_INIT_PROJECT` (default: `openclaw-default`). `agent onboard` can now collect that default project plus Telegram/Discord/Slack provider-bridge secrets so a later `agent openclaw init` can run without extra flags. `openclaw onboard`, `openclaw configure --section channels`, and `openclaw gateway run` remain expert fallbacks only.
- `agent sudo-mode on` enables `sudo` inside agent containers (by relaxing only `no-new-privileges` for those services); `agent sudo-mode off` restores hardened mode.
- `agent rollback all` requires a `release_id`.
- Use `--skip-d5-tests` (or `AGENTIC_SKIP_D5_TESTS=1`) to skip only `D5_gate_external_providers.sh` with a warning when external API access is unavailable.
- `agent cleanup` also removes local stack Docker images and purges state without following symlinks, but it preserves local model directories by default; use `--purge-models` to remove them explicitly.

## Ollama: preload and model link

In `rootless-dev`, the local model symlink is managed via:

```bash
./agent ollama-link
```

Preload then switch to read-only for smoke tests:

```bash
./agent ollama-preload
./agent ollama-models status
./agent ollama unload qwen3-coder:30b
./agent ollama-models ro
./agent ollama-models rw
```

Explicit offload of a local model without going through OpenWebUI:

- `./agent ollama unload <model>` targets the Ollama backend only for now.
- if the model is already gone, the command succeeds with `result=already-unloaded`.
- if the `ollama` backend is not running, the command fails explicitly and does not open any new bind.

To override the stack default local model (also used by preload):

```bash
export AGENTIC_DEFAULT_MODEL=llama3.2:1b
export AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW=65536
```

Model link rollback:

```bash
./agent rollback ollama-link <backup_id|latest>
```

Each `agent ollama unload ...` call also appends an operator trace to `${AGENTIC_ROOT}/deployments/changes.log`.

## ComfyUI: Flux.1-dev bootstrap

Prepare local model layout + manifest:

```bash
./agent comfyui flux-1-dev
```

Remote download (Hugging Face):

```bash
./agent comfyui flux-1-dev --download --hf-token-file /path/to/hf_token
```

The helper now aligns the Flux assets with the ComfyUI runtime paths actually used
by Flux nodes:

- `models/diffusion_models/flux1-dev.safetensors`
- `models/vae/ae.safetensors`
- `models/text_encoders/clip_l.safetensors`
- `models/text_encoders/t5xxl_fp16.safetensors`

Comfy CLI direct model download example (from inside `./agent comfyui` shell):

```bash
comfy model download \
  --url "https://huggingface.co/Comfy-Org/FLUX.1-Krea-dev_ComfyUI/resolve/main/split_files/diffusion_models/flux1-krea-dev_fp8_scaled.safetensors" \
  --relative-path models/diffusion_models \
  --filename flux1-krea-dev_fp8_scaled.safetensors
```

Without `--hf-token-file`, the helper automatically reads `${AGENTIC_ROOT}/secrets/runtime/huggingface.token` when present.

Notes:
- Flux.1-dev is a gated repository (HF license acceptance + token required).
- ComfyUI Journal uses `/ws` websocket through `comfyui-loopback`.
- End-to-end Flux smoke test: `bash tests/I3_comfyui_flux_generate.sh`

Default-model e2e probe (Ollama, gate, agents, OpenWebUI, OpenHands):

```bash
bash tests/L5_default_model_e2e.sh
bash tests/L6_codex_model_catalog.sh
bash tests/L7_default_model_tool_call_fs_ops.sh
bash tests/L10_codex_exec_tool_runtime.sh
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
- `./agent llm test-mode off`: default (production), gate dry-run disabled.
- `./agent llm test-mode on`: explicit enablement for test campaigns.

Example `remote` mode with local pause:

```bash
./agent llm mode remote
./agent stop service ollama trtllm
```

Runtime state:
- mode: `${AGENTIC_ROOT}/gate/state/llm_mode.json`
- quota counters: `${AGENTIC_ROOT}/gate/state/quotas_state.json`
- metrics: `external_requests_total`, `external_tokens_total`, `external_quota_remaining`

## Ollama Drift Watch (Step 14)

Automated upstream contract watch for Ollama launch/integrations/API-compat docs (`codex`, `claude`, `opencode`, `openclaw`, OpenAI compatibility, Anthropic compatibility):

```bash
./agent ollama-drift watch
```

Behavior:
- fetches official upstream docs from `raw.githubusercontent.com/ollama/ollama/main/docs/...`,
- validates key contract invariants (env vars, endpoints, integration commands),
- compares against local baseline files in `${AGENTIC_ROOT}/deployments/ollama-drift/baseline/*.mdx`,
- on drift: exits with code `2`, writes a detailed report under `${AGENTIC_ROOT}/deployments/ollama-drift/reports/`, and auto-creates/updates a Beads issue (default `dgx-spark-agentic-stack-ygu`).

Useful options:
- accept a non-breaking upstream evolution by refreshing baseline snapshots:
  - `./agent ollama-drift watch --ack-baseline`
- disable Beads automation for a specific run:
  - `./agent ollama-drift watch --no-beads`
- target only a subset of sources (Step 7 example for opencode/openclaw):
  - `./agent ollama-drift watch --sources opencode,openclaw`

Weekly scheduling (`rootless-dev`):

```bash
export AGENTIC_PROFILE=rootless-dev
./agent ollama-drift schedule
```

- preferred backend: weekly `systemd --user` timer,
- automatic fallback: user `crontab`,
- removal: `./agent ollama-drift schedule --disable`.

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
AGENTIC_OPTIONAL_MODULES=mcp,pi-mono,goose,portainer ./agent up optional
```

OpenClaw is now part of `core` and starts with:

```bash
./agent up core
```

Runtime prerequisites for the remaining optional modules:
- request files: `${AGENTIC_ROOT}/deployments/optional/*.request`
  - `${AGENTIC_ROOT}/deployments/optional/mcp.request`
  - `${AGENTIC_ROOT}/deployments/optional/pi-mono.request`
  - `${AGENTIC_ROOT}/deployments/optional/goose.request`
  - `${AGENTIC_ROOT}/deployments/optional/portainer.request`
- remaining optional secret:
  - `${AGENTIC_ROOT}/secrets/runtime/mcp.token`

Runtime prerequisites for core OpenClaw:
- secrets:
  - `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`
  - `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`
- versioned OpenClaw profile (runtime bootstrap):
  - `${AGENTIC_ROOT}/openclaw/config/integration-profile.v1.json`
  - `${AGENTIC_ROOT}/openclaw/config/integration-profile.current.json`
- OpenClaw config layers:
  - stack-owned immutable config: `${AGENTIC_ROOT}/openclaw/config/immutable/openclaw.stack-config.v1.json`
  - validated operator overlay: `${AGENTIC_ROOT}/openclaw/config/overlay/openclaw.operator-overlay.json`
  - writable runtime state: `${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/openclaw.state.json`

## Validation

- Global diagnostics: `./agent doctor`
- Explicit stream tool-call probe (codex, claude, openhands, opencode, openclaw, pi-mono, goose): `./agent doctor --check-tool-stream-e2e`
- Repository-driven multi-agent E2E orchestrator: `./agent repo-e2e` (reference repo bootstrapped by `git-forge`: `eight-queens-agent-e2e`)
- Goose verification (context contract + banner aligned with `AGENTIC_GOOSE_CONTEXT_LIMIT`): `./agent test K`
- Test campaigns: `./agent test <A..L|V|all>`
- VM `strict-prod` campaign (evidence + update/rollback + tests): `./agent vm test --name agentic-strict-prod`
- Check VM state: `multipass list` then `multipass info <vm-name>` (`State: Running` expected)
- Cleanup dedicated VM after campaign: `./agent vm cleanup --name agentic-strict-prod`

## Detailed Documentation

- Introduction (stack philosophy and operating model):
  - `docs/runbooks/introduction.md`
- Implementation strategy and refactoring priorities:
  - `docs/runbooks/implementation-strategy-refactoring.md`
- Step-by-step guide (full first deployment):
  - `docs/runbooks/first-time-setup.md`
- Dedicated `strict-prod` VM (prod-like validation):
  - `docs/runbooks/strict-prod-vm.md`
- Dedicated beginner guide for `strict-prod`:
  - `docs/runbooks/strict-prod-pour-debutant.md`
- Ultra-simple onboarding dedicated to `strict-prod`:
  - `docs/runbooks/onboarding-ultra-simple.strict-prod.fr.md`
  - `docs/runbooks/onboarding-ultra-simple.strict-prod.en.md`
- Feature and implemented agent catalog:
  - `docs/runbooks/features-and-agents.md`
- Versioned Ollama agent integration matrix (launch-supported vs internal adapters):
  - `docs/runbooks/ollama-agent-integration-matrix.md`
- Beginner service-by-service guide (French):
  - `docs/runbooks/services-expliques-debutants.md`
- Beginner service-by-service guide (English):
  - `docs/runbooks/services-explained-beginners.en.md`
- Beginner configuration reference (French):
  - `docs/runbooks/configuration-expliquee-debutants.md`
- Beginner configuration reference (English):
  - `docs/runbooks/configuration-explained-beginners.en.md`
- Development images runbook (French, local builds/overrides/stamps/update/rollback):
  - `docs/runbooks/images-developpement.md`
- Ultra-simplified non-technical onboarding (FR/EN/DE/IT/CN/HI):
  - `docs/runbooks/onboarding-ultra-simple.fr.md`
  - `docs/runbooks/onboarding-ultra-simple.en.md`
  - `docs/runbooks/onboarding-ultra-simple.de.md`
  - `docs/runbooks/onboarding-ultra-simple.it.md`
  - `docs/runbooks/onboarding-ultra-simple.cn.md`
  - `docs/runbooks/onboarding-ultra-simple.hi.md`
- Execution profiles:
  - `docs/runbooks/profiles.md`
- Optional modules:
  - `docs/runbooks/optional-modules.md`
- OpenClaw onboarding for this stack (`rootless-dev`):
  - `docs/runbooks/openclaw-onboarding-rootless-dev.md`
- OpenClaw explained for beginners (English):
  - `docs/runbooks/openclaw-explained-beginners.en.md`
- OpenClaw explained for beginners (French):
  - `docs/runbooks/openclaw-explique-debutants.md`
- Observability triage (latency, egress errors, restarts, OOM):
  - `docs/runbooks/observability-triage.md`
- OpenClaw security model (sandbox + controlled egress, no `docker.sock`):
  - `docs/security/openclaw-sandbox-egress.md`

## Internal References

- `AGENTS.md`
- `PLAN.md`
- `docs/runbooks/*.md`
- `docs/decisions/*.md`

## License

This project is distributed under the Apache License 2.0. See `LICENSE`.
Copyright 2026 Pierre-André Vuissoz.
