# ADR-0092: TRT-LLM native runtime with automatic mock fallback

## Context

The repository originally exposed `trtllm` through a lightweight synthetic Python server.
That was sufficient for routing and contract tests, but it did not execute a real TensorRT-LLM backend.

The user request now explicitly targets NVIDIA's DGX Spark TRT-LLM playbook:

- https://build.nvidia.com/spark/trt-llm

As observed on 2026-03-28, the NVIDIA Spark TRT-LLM material documents:

- a TensorRT-LLM release image path already used by the repository,
- `trtllm-serve serve ...`,
- `HF_TOKEN`,
- an OpenAI-compatible server on port `8355`,
- Nemotron-3-Super-120B support listed with the FP8 handle `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-FP8`,
- and a DGX Spark NVFP4 flow based on a prepared local directory such as `/data/super_fp4/`.

The repository still needs deterministic regression coverage on machines where:

- no GPU is available,
- no Hugging Face token is configured,
- or the native model pull would be too heavy for routine tests.

## Decision

1. Replace the mock-only TRT-LLM image with the official NVIDIA TensorRT-LLM container base.
2. Keep the existing stack contract (`/healthz`, `/api/tags`, `/api/chat`, `/api/embeddings`, `/v1/models`) by running a local adapter inside the TRT-LLM container.
3. Introduce `TRTLLM_RUNTIME_MODE=auto|mock|native` with:
   - `auto` as the Compose default,
   - `native` when the Hugging Face token file is present or the configured model is a local path,
   - `mock` otherwise.
4. In native mode, the adapter starts `trtllm-serve serve ...` on loopback inside the container and proxies requests to it.
5. Preserve mock mode for deterministic repository tests that do not ship a real HF token.
6. Keep the user-facing default TRT model slug unchanged in onboarding.
7. Keep `TRTLLM_NATIVE_MODEL_POLICY=auto` as the generic default, including the existing FP8 canonicalization path for the Nemotron NVFP4 alias.
8. Add `TRTLLM_NATIVE_MODEL_POLICY=strict-nvfp4-local-only` for DGX Spark:
   - exactly one TRT model alias is exposed,
   - the exposed alias must be the Nemotron NVFP4 slug (or the same local directory path),
   - the actual serve target becomes `TRTLLM_NVFP4_LOCAL_MODEL_DIR`,
   - and `auto` mode no longer silently falls back to `mock`.
9. When the default TRT Nemotron NVFP4 alias is selected and a Hugging Face token is present, prepare the pinned NVFP4 snapshot automatically under `${AGENTIC_ROOT}/trtllm/models/super_fp4` before the service starts.

## Consequences

- The stack can now run a real TensorRT-LLM backend on DGX Spark when the required GPU and Hugging Face token are present.
- Existing routing/tests remain runnable because the service still has an explicit mock path.
- The native server remains internal-only: `ollama-gate` is still the intended caller.
- Operators get an actionable health signal when native startup fails instead of a silently fake backend.
- In `auto`, the exact native model actually served can still differ from the requested onboarding alias for the Nemotron-3-Super NVFP4 case.
- In `strict-nvfp4-local-only`, the stack serves only a prepared local NVFP4 runtime and fails closed if that runtime is missing or the exposed alias drifts.
- Default TRT onboarding now bootstraps that local NVFP4 runtime automatically when the token is present, while preserving deterministic no-token flows.
