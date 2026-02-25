# ADR-0044: Canonical default model via `AGENTIC_DEFAULT_MODEL`

## Status
Accepted

## Context
The stack had several hardcoded defaults for the local chat model (`qwen3:0.6b`) across runtime/bootstrap paths:
- Ollama preload default,
- OpenHands bootstrap default,
- onboarding prompts.

This made first-run behavior drift-prone when operators wanted another baseline model.

## Decision
1. Introduce `AGENTIC_DEFAULT_MODEL` as canonical runtime default model variable (fallback `qwen3:0.6b`).
2. Reuse it as default source for:
   - `OLLAMA_PRELOAD_GENERATE_MODEL`,
   - onboarding `LLM_MODEL` default for OpenHands,
   - agent/UI runtime environments where model context is needed.
3. Extend onboarding with `--default-model` and persist value in generated env output.
4. Add an end-to-end test (`tests/L5_default_model_e2e.sh`) to verify:
   - model is present in Ollama tags,
   - `hello` generation works through Ollama, gate, agents, OpenWebUI, and OpenHands.

## Consequences
- Operators can set one variable for local baseline model behavior.
- Existing overrides remain compatible (`OLLAMA_PRELOAD_GENERATE_MODEL`, explicit `LLM_MODEL`).
- Full-stack regressions are caught earlier with a deterministic e2e probe for model availability and call path integrity.
