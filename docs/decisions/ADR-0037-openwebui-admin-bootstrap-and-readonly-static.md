# ADR-0037: OpenWebUI admin bootstrap compatibility and writable static path

## Status
Accepted

## Context
`openwebui` was pinned to `ghcr.io/open-webui/open-webui:latest` and runs with `read_only: true`.
On recent Open WebUI versions:
- admin bootstrap env keys are `WEBUI_ADMIN_EMAIL` / `WEBUI_ADMIN_PASSWORD` (not `OPENWEBUI_ADMIN_*`),
- startup writes generated assets under `/app/backend/open_webui/static`.

This created a deadlock in fresh installs:
- `ENABLE_SIGNUP=False`,
- onboarding stayed enabled because admin was never auto-created,
- `POST /api/v1/auths/signup` returned `403`.

It also generated startup write errors because static assets were written on a read-only root filesystem.

## Decision
- Keep `read_only: true` for `openwebui`, but add writable bind mount `${AGENTIC_ROOT}/openwebui/static -> /app/backend/open_webui/static`.
- Switch runtime template/admin docs to `WEBUI_ADMIN_EMAIL` and `WEBUI_ADMIN_PASSWORD`.
- Add backward-compatible migration in `deployments/ui/init_runtime.sh`:
  - `OPENWEBUI_ADMIN_EMAIL -> WEBUI_ADMIN_EMAIL`
  - `OPENWEBUI_ADMIN_PASSWORD -> WEBUI_ADMIN_PASSWORD`
  - `OPENWEBUI_OPENAI_API_KEY -> OPENAI_API_KEY`
- Add H1 regression check that `/api/config` reports `"onboarding": false` after bootstrap.

## Consequences
- Fresh deployments no longer get stuck on onboarding with signup disabled.
- Existing runtime env files are auto-migrated on next `agent up ui`.
- OpenWebUI keeps hardened rootfs posture while allowing required startup writes.
- `openwebui/static` is now part of managed host runtime paths (same permissions policy as `openwebui/data`).
