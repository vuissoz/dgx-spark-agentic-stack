# ADR-0051: Default Local Model and Context Window Policy

## Status
Accepted

## Context
The stack needs a single default local model that is practical for agentic tool-calling across:
- Codex
- Claude Code
- OpenHands
- OpenCode
- Vibestral

Recent local runs also showed tool-calling regressions on `qwen3.5:35b` where pseudo XML-like tags were emitted instead of executable tool calls.

## Decision
1. Set runtime default model to `qwen3-coder:30b` (`AGENTIC_DEFAULT_MODEL` fallback).
2. Introduce `AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW` (default `262144`) and propagate it to `OLLAMA_CONTEXT_LENGTH`.
3. Raise Ollama runtime defaults to support this baseline on DGX Spark:
   - `AGENTIC_LIMIT_OLLAMA_MEM`: `96g` in `strict-prod`, `64g` in `rootless-dev`
   - `OLLAMA_MODEL_STORE_BUDGET_GB`: `32`
4. Extend onboarding to configure context window explicitly (`--default-model-context-window`).
5. Extend `agent doctor` to validate:
   - configured context <= model max context
   - estimated model + KV-cache memory fits `AGENTIC_LIMIT_OLLAMA_MEM`

## Consequences
- Stronger default compatibility with coding/tool-calling agent workflows.
- Higher baseline local resource expectations for Ollama in default configuration.
- Explicit, user-configurable context length at onboarding time.
- Failing fast in doctor when model/context/resource settings are incoherent.
