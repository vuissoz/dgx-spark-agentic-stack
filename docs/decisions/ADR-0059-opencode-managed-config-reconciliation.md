# ADR-0059: Opencode managed config reconciliation on every startup

Date: 2026-03-07
Status: Accepted

## Context

`agentic-opencode` persisted `~/.config/opencode/opencode.json` under `${AGENTIC_ROOT}/opencode/state`.
Without managed bootstrap for this file, first-run defaults could drift to upstream provider defaults (for example `gpt-5.2`) instead of the stack local default model (`AGENTIC_DEFAULT_MODEL`) through `ollama-gate`.

This created a mismatch with the stack contract where baseline agents must start with local-model routing by default.

## Decision

For `AGENT_TOOL=opencode`, `agent-entrypoint` now reconciles `~/.config/opencode/opencode.json` on every startup (idempotent write-if-changed) with managed local defaults:

- `model = "ollama/${AGENTIC_DEFAULT_MODEL}"`
- `small_model = "ollama/${AGENTIC_DEFAULT_MODEL}"`
- provider `ollama` uses `@ai-sdk/openai-compatible`
- provider `ollama.options.baseURL = ${AGENTIC_OLLAMA_GATE_V1_URL:-http://ollama-gate:11435/v1}`
- provider `ollama.models` includes `${AGENTIC_DEFAULT_MODEL}`

The launch-alignment contract test `tests/L8_ollama_launch_alignment_contracts.sh` is extended to assert:

- static pinning of the opencode bootstrap logic in `entrypoint.sh`,
- runtime config alignment (when `agentic-opencode` is running) with `AGENTIC_DEFAULT_MODEL` and gate `/v1`.

## Consequences

- Opencode startup behavior becomes deterministic and aligned with stack local-default LLM policy.
- Existing opencode state that points to external defaults is auto-corrected after service restart.
- Unmanaged edits to the same opencode model/provider keys are not preserved; custom behavior must be implemented through explicit stack configuration.
