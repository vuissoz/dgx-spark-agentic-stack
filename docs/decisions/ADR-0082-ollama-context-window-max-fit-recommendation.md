# ADR-0082: Recommend Ollama Context Windows From Max-Fit Memory Estimates

## Status
Accepted

## Context
The stack already validates `AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW` in `agent doctor`, but the operator experience was still weak for large-context models:
- onboarding kept a fixed default context even when the chosen model could not fit it under `AGENTIC_LIMIT_OLLAMA_MEM`,
- doctor reported the memory shortfall, but not the maximum context that would actually fit.

This was visible on models such as `nemotron-cascade-2:30b`, where the model-wide max context (`262144`) is much larger than the practical context that fits in a constrained Ollama memory budget.

## Decision
1. Factor a shared Ollama context estimator from model metadata:
   - model size from `/api/tags`,
   - architecture fields from `/api/show`,
   - KV cache bytes per token derived from layer count, KV head count, and key length.
2. Compute the maximum fitting context for a given `AGENTIC_LIMIT_OLLAMA_MEM` using:
   - `model_size_bytes + safety_overhead + context * kv_bytes_per_token <= mem_limit_bytes`.
3. Reuse that estimator in both:
   - `agent doctor`, to report the maximum fitting context and propose a corrective value,
   - `agent onboard`, to propose or auto-select the recommended context when the operator did not force one explicitly.
4. Preserve the historical fallback (`262144`) only when metadata is unavailable.

## Consequences
- The recommendation is model-aware instead of relying on a single hard-coded default.
- `agent doctor` becomes directly actionable when context and memory diverge.
- Onboarding stays backward-compatible for models that already fit the historical default (for example `qwen3-coder:30b` under the current defaults), while correcting oversized defaults for tighter models.
