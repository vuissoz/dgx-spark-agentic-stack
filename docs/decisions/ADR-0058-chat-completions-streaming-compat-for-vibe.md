# ADR-0058: `/v1/chat/completions` streaming compatibility for Vibestral interactive mode

Date: 2026-03-07
Status: Accepted

## Context

In `rootless-dev`, `vibe -p` succeeded but interactive `vibe` failed with:

- `API error from ollama-gate ... Stream chunk improperly formatted`

Root cause: `ollama-gate` endpoint `/v1/chat/completions` ignored `stream=true` and always returned a single JSON body (`chat.completion`) instead of SSE frames (`chat.completion.chunk` + `[DONE]`).

Interactive clients that parse SSE (including Vibestral interactive mode) treated the JSON body as malformed stream chunks.

## Decision

1. Update `/v1/chat/completions` handler to honor `stream` from payload.
2. Add `build_chat_completion_stream(...)` in `deployments/gate/app.py` to emit OpenAI-style SSE data frames:
   - `data: { ... \"object\":\"chat.completion.chunk\" ... }`
   - terminal chunk with `finish_reason`
   - `data: [DONE]`
3. Extend `tests/D8_gate_protocol_compat.sh` with a dedicated `/v1/chat/completions` stream check.

## Consequences

- Vibestral interactive mode can consume `ollama-gate` chat streaming without parse errors.
- OpenAI-compatible streaming behavior is now explicit and regression-tested.
- Non-stream behavior remains unchanged for clients that do not request streaming.
