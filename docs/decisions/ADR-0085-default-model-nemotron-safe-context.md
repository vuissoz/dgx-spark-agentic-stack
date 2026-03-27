# ADR-0085: Default local model switches to `nemotron-cascade-2:30b` with a safe baseline context

## Status
Accepted

## Context

The repository previously used `qwen3-coder:30b` with a default context window of `262144`.

The operator now wants the repository defaults to point to `nemotron-cascade-2:30b`. A direct string swap would be incomplete because the stack's default Ollama memory budgets do not fit `nemotron-cascade-2:30b` at `262144` tokens:

- under the default `rootless-dev` budget (`AGENTIC_LIMIT_OLLAMA_MEM=64g`), the estimator computes a max fitting context of `50909`;
- under the default `strict-prod` budget (`AGENTIC_LIMIT_OLLAMA_MEM=96g`), the estimator computes a max fitting context of `91239`.

Keeping `262144` as the repository default would make fresh installs warn in `agent doctor` by default.

## Decision

1. Change the repository default model to `nemotron-cascade-2:30b`.
2. Change the repository default context window to `50909`, which fits the tighter default `rootless-dev` budget.
3. Keep onboarding's estimator-based recommendation flow so larger memory budgets can still auto-select a higher value (for example `108883` under `110g`).
4. Keep `qwen3-coder:30b` only as an explicit fallback recommendation for known tool-calling regressions on other models.

## Consequences

- Fresh runtime defaults stay coherent with `agent doctor` under both supported profiles.
- Non-interactive onboarding can still raise the context automatically when model metadata and a larger memory budget are available.
- Existing historical ADRs and compatibility tests may still mention `qwen3-coder:30b` where they describe prior defaults or fallback guidance; those references are historical, not normative runtime defaults.
