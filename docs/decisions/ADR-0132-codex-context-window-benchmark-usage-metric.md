# ADR-0132: Codex context benchmark uses Codex-reported turn usage as the occupancy metric

## Status
Accepted

## Context

The Codex context saturation benchmark must prove that a single Codex session accumulates multiple French Jules Verne novels and then produces per-book summaries plus a final consolidated summary.

The benchmark needs an operator-facing notion of "context window size at each summary step". Estimating that from raw file bytes or local tokenizers would be imprecise because the effective prompt seen by Codex includes:

- prior turns in the resumed session,
- Codex's own hidden/session framing,
- any server-side tokenization differences.

## Decision

The benchmark resumes the same `codex exec` session for every turn and records the `usage.input_tokens` and `usage.cached_input_tokens` values emitted by Codex in the `turn.completed` JSON event.

The report also records the configured context window from `AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW` / `OLLAMA_CONTEXT_LENGTH` so operators can compare:

- configured context budget,
- actual input-token occupancy at each synthesis turn,
- fill percentage derived from `input_tokens / configured_context_window`.

## Consequences

- The metric reflects what Codex reports for the actual request, not a local estimate.
- The measurement remains valid even if upstream tokenization changes.
- `cached_input_tokens` can stay at `0`; it is still reported for traceability because cache behavior may vary by runtime/provider.
