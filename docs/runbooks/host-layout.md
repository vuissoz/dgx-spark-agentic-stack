# Host layout contract (`/srv/agentic`)

Step 0 defines the runtime filesystem contract used by all later deployment steps.

## Target directories

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
- `/srv/agentic/rag/`
- `/srv/agentic/rag/{qdrant,qdrant-snapshots,docs,scripts,retriever/{state,logs},worker/{state,logs},opensearch,opensearch-logs}/`
- `/srv/agentic/monitoring/`
- `/srv/agentic/{claude,codex,opencode,vibestral}/{state,logs,workspaces}/`
- `/srv/agentic/shared-ro/`
- `/srv/agentic/shared-rw/`
- `/srv/agentic/deployments/{releases,current}/`

## Notes

- `./agent` is the repo entrypoint and mirrors the future `/srv/agentic/bin/agent` behavior.
- Runtime root defaults to `/srv/agentic` and can be overridden with `AGENTIC_ROOT` for local tests.
- Step A introduces the idempotent host bootstrap that creates this tree with strict permissions: `deployments/bootstrap/init_fs.sh`.
- Host readiness commands are documented in `deployments/README-host.md`.
