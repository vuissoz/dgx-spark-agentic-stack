# ADR-0039: Align OpenHands env keys with upstream local LLM setup

## Status
Accepted

## Context

OpenHands local setup expects `LLM_MODEL` and `LLM_API_KEY` in environment configuration.
Our onboarding/runtime templates were writing legacy keys (`OPENHANDS_LLM_MODEL` and `OPENHANDS_LLM_API_KEY`), which made first-run local model setup unreliable.

This was especially visible in onboarding flows where users expected OpenHands to work immediately with local `ollama-gate` routing.

## Decision

1. Switch generated/template OpenHands config to:
   - `LLM_MODEL`
   - `LLM_API_KEY`
2. Use local-friendly defaults in onboarding/template:
   - `LLM_MODEL=qwen3:0.6b`
   - `LLM_API_KEY=local-ollama`
3. Keep compatibility for existing installs by migrating legacy keys to the new keys in `deployments/ui/init_runtime.sh` when needed.
4. Update tests and runbooks to reference the upstream key names and clarify that local mode accepts any non-empty API key placeholder.

## Consequences

- New onboarding runs produce OpenHands config that matches upstream expectations.
- Existing hosts with legacy key names are auto-repaired on next `agent up ui`.
- Operator docs now match runtime behavior for local model usage.
