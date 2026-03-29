# ADR-0095: Publish stack-managed compaction thresholds to agents

## Status
Accepted

## Context

The stack already manages a default local context budget through:

- `AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW`,
- `OLLAMA_CONTEXT_LENGTH`,
- onboarding and `agent doctor`, which can estimate a max fitting context from Ollama metadata and `AGENTIC_LIMIT_OLLAMA_MEM`.

What was still missing was an explicit runtime policy telling agents when they should begin compacting or summarizing their own conversation history before they approach the hard backend limit.

Without that policy signal:

- agent runtimes only know the nominal context window,
- each agent surface has to guess its own safety margin,
- `agent doctor` cannot validate whether published compaction hints remain coherent with the effective context budget.

## Decision

1. The stack now publishes a shared compaction policy derived from the effective context budget:
   - `AGENTIC_CONTEXT_BUDGET_TOKENS`,
   - `AGENTIC_CONTEXT_COMPACTION_SOFT_PERCENT` (default `75`),
   - `AGENTIC_CONTEXT_COMPACTION_DANGER_PERCENT` (default `90`),
   - `AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS`,
   - `AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS`.
2. The effective budget is derived from the configured runtime window:
   - `min(AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW, OLLAMA_CONTEXT_LENGTH)`,
   - and `agent doctor` cross-checks it against the estimator-derived max fitting context when model metadata is available.
3. The stack remains responsible for publishing policy signals only:
   - `codex` receives the soft threshold as `auto_compact_token_limit` plus explicit base instructions,
   - `goose` and `openhands` receive the same thresholds through runtime environment variables,
   - other CLI agents receive the managed values through the shared bootstrap defaults.
4. Semantic compaction remains an agent responsibility:
   - the stack does not compact messages itself,
   - the backend remains responsible only for hard enforcement through actual context/KV-cache limits.

## Consequences

- Agent runtimes now receive a consistent early-warning (`soft`) and near-limit (`danger`) signal.
- `agent doctor` can flag drift between memory budget, effective context budget, and the published thresholds.
- Operators may tune the percent policy, but the repository defaults remain deterministic (`75%` / `90%`).
