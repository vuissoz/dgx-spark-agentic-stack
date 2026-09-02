# ADR-0153 — Default local model is `qwen3.8:27b`

## Decision

Use `qwen3.8:27b` as the repository-wide default for agent runtimes, OpenHands, OpenClaw, Goose, n8n Instance AI, preload, onboarding and model-broker fallback paths.

Explicit model settings remain supported and continue to take precedence. Embedding, vision and TRT-LLM model settings are specialized paths and are not replaced by this default.

## Rationale

The DGX runtime currently exposes `qwen3.8:27b` in the Ollama gate catalog. The former defaults were split between `qwen3-coder:30b`, `nemotron-cascade-2:30b` and the invalid short n8n alias `qwen3.8`. A single canonical identifier avoids silent model mismatches, including n8n streaming failures.

## Operational note

After changing the default on an existing installation, redeploy the affected profiles so containers receive the new environment:

```bash
AGENTIC_DEFAULT_MODEL=qwen3.8:27b \
AGENTIC_AGENT_DEFAULT_MODEL=qwen3.8:27b \
AGENTIC_N8N_AI_MODEL=qwen3.8:27b \
./agent stack start all
```
