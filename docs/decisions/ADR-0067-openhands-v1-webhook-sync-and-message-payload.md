# ADR-0067 — OpenHands V1 Event Sync + Legacy Message Payload Compatibility

Date: 2026-03-08

## Context

In rootless-dev mode, OpenHands V1 conversations could reach `READY` but remain stuck as "disconnected":

- `/api/conversations/{id}/message` returned success, but runtime received empty user messages.
- `/api/v1/conversation/{id}/events/search` remained empty even while runtime `/events/search` had events.

This happened because:

1. Legacy bridge payloads (`message`/`action`/`args`) were forwarded directly to the V1 agent-server `SendMessageRequest` endpoint, which expects `{role, content, run}`.
2. Agent sandboxes were started without `OH_WEBHOOKS_*` configuration, so runtime events were not posted back to `/api/v1/webhooks/events/{conversation_id}`.

## Decision

1. Normalize legacy `/api/conversations/{id}/events` and `/message` payloads to V1 `SendMessageRequest` shape:
   - `role=user`
   - `content=[{type:\"text\", text:\"...\"}]`
   - `run=true`
2. Enable V1 webhook propagation in OpenHands service environment:
   - `OH_WEBHOOKS_0_BASE_URL=http://127.0.0.1:3000/api/v1/webhooks`
   - `OH_WEBHOOKS_0_EVENT_BUFFER_SIZE=1`
   - `OH_WEBHOOKS_0_FLUSH_DELAY=1.0`
3. Strengthen regression test `tests/H2_openhands.sh`:
   - verify `/message` success
   - then verify `/api/v1/conversation/{id}/events/search` receives non-empty events containing the posted message text.

## Consequences

- V1 conversations in rootless-dev no longer appear permanently disconnected after sending a message.
- App-side event APIs reflect runtime activity quickly, matching frontend expectations.
- The test suite now catches both "success-with-empty-message" and "runtime-events-not-synced" regressions.
