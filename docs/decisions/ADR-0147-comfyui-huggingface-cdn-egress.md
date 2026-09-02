# ADR-0147: Allow the Hugging Face AWS CDN for ComfyUI model bundles

## Status

Accepted

## Context

ComfyUI model artifacts requested from `huggingface.co` are redirected to
`us.aws.cdn.hf.co`. Allowing only the repository host therefore permits metadata
access but causes Squid to reject the actual artifact transfer with HTTP 403.

## Decision

- Add the exact host `us.aws.cdn.hf.co` to the canonical proxy allowlist.
- Keep HTTPS-only proxy enforcement and do not add wildcard AWS or Hugging Face
  domains.
- Have `agent doctor` require both the Hugging Face repository and artifact CDN
  hosts when ComfyUI is running.

## Consequences

ComfyUI can download public Hugging Face artifacts through the controlled proxy.
The added egress surface is restricted to the concrete CDN host observed for the
declared MiniMax-H3 and Flux.2 files.
