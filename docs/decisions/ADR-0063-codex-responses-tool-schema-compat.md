# ADR-0063: Codex Responses function-tool schema compatibility in ollama-gate

## Status
Accepted

## Context

In `rootless-dev`, Codex CLI routed through `ollama-gate` could not use local tools while other agent paths were functional.

Investigation showed Codex sends Responses API tools using top-level function schema:
- `{"type":"function","name":"...","parameters":{...}}`

`ollama-gate` only normalized:
- chat-style nested schema `{"type":"function","function":{"name":"...","parameters":{...}}}`

Because of this mismatch, Codex tool definitions were dropped before upstream routing, causing tool-unavailable behavior in Codex sessions.

## Decision

- Extend `normalize_tools_payload` in `deployments/gate/app.py` to accept both:
  - nested chat-style function tools,
  - top-level Responses-style function tools.
- Keep normalized upstream representation unchanged (OpenAI chat-compatible `tools` list).
- Add a regression check in `tests/D8_gate_protocol_compat.sh` validating `/v1/responses` with Codex-style top-level function tools schema.

## Consequences

- Codex requests using Responses top-level function tools are forwarded correctly.
- Tool-call compatibility checks now cover both function-tool schemas, reducing regression risk for Codex integrations.
