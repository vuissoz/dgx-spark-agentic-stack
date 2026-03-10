# ADR-0069: Align Goose default context limit with default model context window

## Status
Accepted

## Context
- ADR-0068 introduced `AGENTIC_GOOSE_CONTEXT_LIMIT` with a fixed default (`128000`) to make Goose banner behavior deterministic.
- Runtime defaults already define `AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW` (default `262144` for `qwen3-coder:30b`) and propagate it to `OLLAMA_CONTEXT_LENGTH`.
- Keeping Goose on a separate fixed default causes avoidable drift between:
  - configured model context (`AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW`),
  - backend context (`OLLAMA_CONTEXT_LENGTH`),
  - Goose client context (`AGENTIC_GOOSE_CONTEXT_LIMIT`).

## Decision
1. Keep `AGENTIC_GOOSE_CONTEXT_LIMIT` as an explicit Goose client variable.
2. Change its default to align with `AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW`:
   - runtime default: `AGENTIC_GOOSE_CONTEXT_LIMIT=${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW}`,
   - compose fallback: same alignment when env is unset.
3. Update onboarding-generated env to always export `AGENTIC_GOOSE_CONTEXT_LIMIT`, defaulting to the selected `AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW`.
4. Keep doctor and regression tests enforcing that Goose uses the configured `GOOSE_CONTEXT_LIMIT`.

## Consequences
- Default Goose context is now aligned with the selected default model window (for `qwen3-coder:30b`, default `262144`).
- Operators still retain an explicit override path via `AGENTIC_GOOSE_CONTEXT_LIMIT`.
- Onboarding outputs are self-contained and explicit about Goose context behavior.
