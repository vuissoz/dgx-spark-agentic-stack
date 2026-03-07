# ADR-0057: Vibestral managed config reconciliation on every startup

Date: 2026-03-07
Status: Accepted

## Context

`agentic-vibestral` persisted `~/.vibe/config.toml` under `${AGENTIC_ROOT}/vibestral/state`.
The previous bootstrap only wrote defaults on first run (or one specific legacy migration pattern), then stopped reconciling.

In `rootless-dev`, this allowed drift between:

- runtime default model (`AGENTIC_DEFAULT_MODEL`),
- gate endpoint expectations (`ollama-gate /v1`),
- and persisted Vibestral provider/model settings.

The observed operator impact was intermittent `vibe` failures such as `API error from ollama-gate`, while `codex`/`claude` continued to work through managed defaults.

## Decision

For `AGENT_TOOL=vibestral`, `agent-entrypoint` now reconciles `~/.vibe/config.toml` on every startup (idempotent write-if-changed), with managed local-gate defaults:

- `active_model = "local-gate"`
- provider `ollama-gate` at `http://ollama-gate:11435/v1`
- `api_key_env_var = "OPENAI_API_KEY"`
- model name pinned to `${AGENTIC_DEFAULT_MODEL}`

The contract test `tests/L9_ollama_internal_adapter_contracts.sh` is extended to assert:

- static adapter pinning (`api_key_env_var`),
- runtime config alignment with `AGENTIC_DEFAULT_MODEL`,
- runtime `OPENAI_API_KEY` wiring.

## Consequences

- Vibestral startup behavior becomes deterministic and aligned with the stack's managed LLM routing model.
- Existing drifted Vibestral state is auto-corrected after service restart.
- Users lose the ability to keep unmanaged edits in `~/.vibe/config.toml` for the baseline `agentic-vibestral` service; custom behavior must be introduced through explicit stack configuration changes.
