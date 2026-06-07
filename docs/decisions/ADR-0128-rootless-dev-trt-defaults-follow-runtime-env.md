# ADR-0128: `rootless-dev` TRT defaults follow the active runtime envelope

## Status
Accepted

## Context

The repository had drifted back to a TRT default tuned for the larger Nemotron Super 120B path:

- `TRTLLM_MODELS=https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4`
- `TRTLLM_NATIVE_MAX_NUM_TOKENS=262144`
- `TRTLLM_NATIVE_MAX_SEQ_LEN=262144`

That no longer matched the operator's active `rootless-dev` runtime under `~/.local/share/agentic/deployments/runtime.env`, which had already been reduced to a smaller TRT model and tighter limits to avoid excessive memory pressure:

- `TRTLLM_MODELS=https://huggingface.co/nvidia/Qwen3-32B-FP4`
- `TRTLLM_NATIVE_MAX_NUM_TOKENS=8192`
- `TRTLLM_NATIVE_MAX_SEQ_LEN=98304`

Keeping the repository defaults larger than the runtime made fresh onboarding and rootless re-deployments regress toward an oversized TRT footprint.

## Decision

For `rootless-dev` only:

1. default `TRTLLM_MODELS` to `https://huggingface.co/nvidia/Qwen3-32B-FP4`;
2. default `TRTLLM_NATIVE_MAX_NUM_TOKENS` to `8192`;
3. default `TRTLLM_NATIVE_MAX_SEQ_LEN` to `98304`.

`strict-prod` keeps the larger Super 120B defaults unchanged.

## Consequences

- `rootless-dev` onboarding and runtime defaults now match the active operator runtime;
- local redeployments stop drifting back to the oversized Super 120B TRT profile;
- prod-like validation can still exercise the larger TRT profile under `strict-prod`.
