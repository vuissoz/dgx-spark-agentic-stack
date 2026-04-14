# ADR-0103 - OpenWebUI explicit model selection and Ollama GPU diagnostics

## Context

OpenWebUI uses the OpenAI-compatible gate endpoint and can send requests without a stable `X-Agent-Session`, which makes those requests fall back to the `anonymous` gate session. A stale sticky model on that session can silently override a newly selected OpenWebUI model.

The same incident showed `nemotron-cascade-2:30b` loaded by Ollama with `PROCESSOR=100% CPU` while the stack expected GPU offload.

## Decision

For OpenAI-compatible gate endpoints, an explicit request `model` now updates the sticky session even when `X-Model-Switch` is absent. The explicit admin switch endpoint remains supported, and native Ollama API endpoints keep the existing sticky behavior unless the client opts into `X-Model-Switch`.

`agent doctor` now reports:

- the current `anonymous` sticky model and recent OpenAI-compatible model mismatch logs,
- whether the Ollama container has a Docker GPU device request,
- whether `/dev/nvidia*` and in-container `nvidia-smi` are usable when GPU is expected,
- whether the loaded default Ollama model is reported by `ollama ps` as CPU-only.

The Ollama compose service also exports `NVIDIA_VISIBLE_DEVICES=all` and `NVIDIA_DRIVER_CAPABILITIES=compute,utility` by default to make the intended NVIDIA runtime contract explicit.

## Consequences

OpenWebUI model selection no longer depends on sending `X-Model-Switch`. A stale `anonymous` entry remains visible in diagnostics, but it should be replaced by the next explicit OpenAI-compatible model request.

If Ollama reports `100% CPU` for the default model while GPU is expected, `doctor` surfaces an actionable warning in rootless-dev and a failure in strict-prod.
