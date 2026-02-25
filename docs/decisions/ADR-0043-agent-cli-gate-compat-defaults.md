# ADR-0043: Agent CLI zero-touch local defaults and gate protocol compatibility shims

## Status
Accepted

## Context
In `rootless-dev`, starting `agent codex`, `agent claude`, and `agent vibestral` should work without first-run API key onboarding and should route by default through `ollama-gate`.

Observed gaps:
- session bootstrap command could lose the leading `c` in `cd`, producing `bash: d: command not found`.
- `codex` targets OpenAI Responses API (`/responses` or `/v1/responses`) and `claude` targets Anthropic Messages API (`/messages` or `/v1/messages`), but gate only exposed `/v1/chat/completions`.
- first-run defaults did not always include the non-empty placeholder keys expected by CLIs.

## Decision
- Fix `agent` tmux bootstrap to send `C-c` and `cd ...` in separate `tmux send-keys` invocations.
- Extend first-run agent defaults to include:
  - `OPENAI_API_KEY=local-ollama`
  - `ANTHROPIC_BASE_URL=http://ollama-gate:11435`
  - `ANTHROPIC_API_KEY=local-ollama`
  - `ANTHROPIC_MODEL=${AGENTIC_DEFAULT_MODEL}`
- Keep defaults backward-compatible by appending missing exports to existing `ollama-gate-defaults.env` files instead of replacing operator overrides.
- Add first-run bootstrap configs:
  - `~/.codex/config.toml` with provider `ollama-gate` and `wire_api="responses"`.
  - `~/.vibe/config.toml` with a local OpenAI-compatible provider pointed to gate and no API-key env requirement.
- Extend `ollama-gate` with compatibility endpoints:
  - OpenAI Responses: `/responses`, `/v1/responses`
  - Anthropic Messages: `/messages`, `/v1/messages`
  - Both route through the same queue/sticky/quota/backend logic as `/v1/chat/completions`.

## Consequences
- `codex`, `claude`, and `vibestral` can start on fresh runtime state without interactive API key setup for local routing.
- Existing runtime states receive missing defaults safely during bootstrap.
- Gate remains a single local control plane while supporting client protocol variants required by modern CLIs.
