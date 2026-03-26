# Host layout contract

Step 0 defines the runtime filesystem contract used by all later deployment steps.
The canonical runtime root depends on profile:
- `strict-prod`: `/srv/agentic`
- `rootless-dev`: `${HOME}/.local/share/agentic`

## Target directories (`strict-prod`)

- `/srv/agentic/deployments/`
- `/srv/agentic/bin/agent`
- `/srv/agentic/tests/`
- `/srv/agentic/secrets/`
- `/srv/agentic/ollama/`
- `/srv/agentic/gate/{config,state,logs}/`
- `/srv/agentic/trtllm/{models,state,logs}/` (when `COMPOSE_PROFILES=trt` is enabled)
- `/srv/agentic/proxy/`
- `/srv/agentic/dns/`
- `/srv/agentic/openwebui/`
- `/srv/agentic/openhands/`
- `/srv/agentic/comfyui/`
- `/srv/agentic/openclaw/`
- `/srv/agentic/openclaw/{config,state,logs,relay/{state,logs},sandbox/state,workspaces}/`
- `/srv/agentic/rag/`
- `/srv/agentic/rag/{qdrant,qdrant-snapshots,docs,scripts,retriever/{state,logs},worker/{state,logs},opensearch,opensearch-logs}/`
- `/srv/agentic/monitoring/`
- `/srv/agentic/{claude,codex,opencode,vibestral}/{state,logs,workspaces}/`
- `/srv/agentic/optional/{mcp,pi-mono,goose,portainer}/`
- `/srv/agentic/shared-ro/`
- `/srv/agentic/shared-rw/`
- `/srv/agentic/deployments/{releases,current}/`

## Target directories (`rootless-dev`)

The same runtime contract exists under `${HOME}/.local/share/agentic`, with one notable difference for baseline agent workspaces:
- `${HOME}/.local/share/agentic/agent-workspaces/{claude,codex,opencode,vibestral}/workspaces/`

Everything else stays under the profile root unless explicitly overridden:
- `${HOME}/.local/share/agentic/openclaw/...`
- `${HOME}/.local/share/agentic/openhands/...`
- `${HOME}/.local/share/agentic/optional/...`
- `${HOME}/.local/share/agentic/deployments/{releases,current}/`

## Notes

- `./agent` is the repo entrypoint and mirrors the future `/srv/agentic/bin/agent` behavior.
- Runtime root defaults to `/srv/agentic` in `strict-prod` and `${HOME}/.local/share/agentic` in `rootless-dev`.
- Workspace path variables (`AGENTIC_CODEX_WORKSPACES_DIR`, `AGENTIC_CLAUDE_WORKSPACES_DIR`, etc.) are the source of truth when profiles override host paths.
- Step A introduces the idempotent host bootstrap that creates this tree with strict permissions: `deployments/bootstrap/init_fs.sh`.
- Host readiness commands are documented in `deployments/README-host.md`.
