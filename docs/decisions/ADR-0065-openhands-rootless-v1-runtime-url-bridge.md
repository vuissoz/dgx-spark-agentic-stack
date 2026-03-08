# ADR-0065: Keep OpenHands V1 conversation URL browser-reachable in rootless process sandbox

## Status
Accepted

## Context
In `rootless-dev`, OpenHands V1 startup could reach `READY` while the UI conversation page remained `disconnected`.

Runtime evidence showed:
- `POST /api/v1/app-conversations` + start-task polling reached `READY`.
- `LLM_BASE_URL=http://ollama-gate:11435/v1` was correct and direct chat calls from OpenHands to `ollama-gate` succeeded.
- `GET /api/conversations/{id}` returned `url=http://localhost:8000/api/conversations/{id}`.

For process sandboxes, this `localhost:8000` endpoint is internal to the OpenHands container namespace and not reachable from the browser. So the issue was not Ollama connectivity, but an unreachable runtime URL exposed to the frontend.

## Decision
1. In the mounted OpenHands patch `live_status_app_conversation_service.py`, build `conversation_url` as a browser-facing bridge path when runtime base URL is loopback-only:
   - fallback path: `/api/conversations/{id}`
   - keep direct runtime URL only when it is not loopback-only.
2. In the mounted patch `server/routes/conversation.py`, resolve runtime forwarding endpoint from V1 start-task metadata (`agent_server_url`) instead of relying on `app_conversation.conversation_url`.
   - keeps `/api/conversations/{id}/events` and `/message` forwarding bound to the real runtime endpoint.
3. Extend `tests/H2_openhands.sh` to assert that V1 conversation URL is not `http://localhost:8000/...` and that posting via the bridged conversation URL succeeds.

## Consequences
- New V1 conversations in `rootless-dev` no longer remain disconnected due to an unreachable internal runtime URL.
- Legacy bridge endpoints still forward to the real runtime endpoint using `agent_server_url`.
- No security baseline change: no `docker.sock`, no public bind, no extra host-exposed runtime ports.
