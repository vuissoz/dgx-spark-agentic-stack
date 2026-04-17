# ADR-0108 - Relay native Ollama chat streaming through `ollama-gate`

Date: 2026-04-17
Status: Accepted

## Context

OpenWebUI is configured against `ollama-gate` using the OpenAI-compatible `/v1` API. The gate already emitted OpenAI-style SSE frames for `/v1/chat/completions`, but for local Ollama backends it synthesized those frames only after buffering the full upstream response.

That behavior had two operator-visible effects in `rootless-dev`:

- OpenWebUI could not render token-by-token output for local Ollama models even when `stream=true`.
- Slow chat requests monopolized the gate slot while helper calls such as `/v1/models` waited behind them, amplifying queue timeouts and making the UI look stalled.

Existing true streaming passthrough was only enabled for the `trtllm` backend, even though the local Ollama backend also exposes an OpenAI-compatible streaming endpoint at `/v1/chat/completions`.

## Decision

1. Resolve the backend protocol before dispatching the chat request.
2. When `stream=true` and the selected backend protocol is `ollama`, relay the upstream `/v1/chat/completions` byte stream directly instead of buffering the full completion first.
3. Keep the synthetic SSE builder for non-passthrough cases such as dry-run responses and non-Ollama backends.
4. Add regression coverage that distinguishes true passthrough from the old buffered behavior by using a mock Ollama upstream with:
   - immediate streaming chunks on `/v1/chat/completions`,
   - delayed buffered JSON on `/api/chat`.

## Consequences

- OpenWebUI can display progressive generation for local Ollama models through `ollama-gate`.
- The gate still preserves its queue semantics: the active slot remains held for the lifetime of the upstream stream.
- Existing TRT-LLM streaming behavior remains unchanged because it already uses the Ollama-compatible streaming path.
- Secondary OpenWebUI helper-flow behavior, such as title generation against unavailable models, remains a separate concern and can be followed up independently if still reproducible after the passthrough fix.
