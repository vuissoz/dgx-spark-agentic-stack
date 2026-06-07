# ADR-0122: Expose the full Nemotron Super context window on DGX Spark

## Status
Accepted

## Context

The TRT-LLM path now defaults to `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` on DGX Spark.
The repository still capped the runtime with:

- `TRTLLM_NATIVE_MAX_SEQ_LEN=32768`
- `TRTLLM_NATIVE_MAX_NUM_TOKENS=4096`

Those values were intentionally conservative while the Super path was being stabilized, but they no longer match the model or the observed DGX Spark headroom:

- the model config advertises `max_position_embeddings=262144`;
- the live Spark runtime exposes `121.69 GiB` of device memory;
- the TRT-LLM native warmup logs show a peak around `94 GiB` with about `22 GiB` still available for KV cache at batch size 1.

In practice, the old defaults artificially truncated the available prompt budget long before memory became the limiting factor.

## Decision

Raise the default TRT-LLM limits for the Spark Super profile to the model maximum:

1. `TRTLLM_NATIVE_MAX_SEQ_LEN=262144`
2. `TRTLLM_NATIVE_MAX_NUM_TOKENS=262144`
3. Keep the other Spark safety defaults unchanged for now:
   - `TRTLLM_NATIVE_MAX_BATCH_SIZE=1`
   - `TRTLLM_NATIVE_ENABLE_CUDA_GRAPH=false`

The stack continues to prefer a single-request, single-model Spark setup; the change only removes the unnecessary context cap.

## Consequences

Positive:

- agents using the TRT default model inherit the full advertised context window;
- OpenWebUI and gate clients can submit substantially larger prompts without hitting the old stack cap;
- the defaults now match the actual model contract on Spark.

Trade-offs:

- worst-case prefill requests can take longer;
- a true max-context prompt is still expensive and should remain a single-request path on Spark;
- if future TRT-LLM releases regress on long-context stability, the limit may need to be reduced again with evidence.

## Verification

Validation for this change must include:

1. default env generation exporting `262144` for both TRT context variables;
2. compose rendering exposing the same values in the `trtllm` service;
3. a live DGX Spark request at the configured context ceiling.
