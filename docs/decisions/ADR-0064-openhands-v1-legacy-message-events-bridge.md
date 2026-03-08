# ADR-0064: Bridge legacy OpenHands conversation routes to V1 runtime endpoints

## Status
Accepted

## Context
In `rootless-dev`, OpenHands UI could remain on the landing flow (`"Let's start building!"`) while conversation startup tasks reached `READY`.

Runtime evidence showed:
- `POST /api/v1/app-conversations` + `/start-tasks` reached `READY`.
- Legacy routes used by the web flow then failed with `404`:
  - `POST /api/conversations/{id}/message`
  - `POST /api/conversations/{id}/events`
- Server logs emitted:
  - `get_conversation: conversation <id> not found, attach_to_conversation returned None`

The legacy routes depended on `get_conversation` (V0 conversation manager attach). For V1 process-sandbox conversations, this attach path was not reliable in this deployment mode, even when the V1 conversation existed and exposed `conversation_url` + `session_api_key`.

## Decision
Add a mounted patch for `openhands/server/routes/conversation.py` that:
1. Detects V1 conversations via `AppConversationService`.
2. Resolves runtime endpoint from V1 metadata (`conversation_url`, `session_api_key`).
3. Forwards legacy `/events` and `/message` payloads to `${conversation_url}/events` with `X-Session-API-Key` when available.
4. Keeps existing V0 behavior unchanged (attach and send via `conversation_manager`).

Also mount this patch in `compose/compose.ui.yml`:
- `deployments/patches/openhands/conversation.py -> /app/openhands/server/routes/conversation.py:ro`

And extend `tests/H2_openhands.sh` with a regression check that creates a READY V1 conversation and verifies `POST /api/conversations/{id}/message` returns success.

## Consequences
- Rootless OpenHands startup flow remains compatible with UI calls that still hit legacy conversation endpoints.
- No relaxation of sandbox/security controls (`docker.sock` remains absent, loopback exposure unchanged).
- Future upstream changes may remove legacy routes; this bridge should then be removed when frontend no longer depends on them.
