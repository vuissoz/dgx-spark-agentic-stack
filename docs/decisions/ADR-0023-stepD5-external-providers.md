# ADR-0023 — Step D5: External LLM providers via ollama-gate (OpenAI/OpenRouter)

## Status
Accepted

## Context
Plan step D5 requires `ollama-gate` to route selected models to external providers while keeping client API unchanged (`/v1/*`), preserving proxy-enforced egress, and keeping provider credentials out of git.

## Decision
1. Extend `ollama-gate` backend config to support provider protocol `openai` (used by both OpenAI and OpenRouter).
2. Keep routing policy versioned in `${AGENTIC_ROOT}/gate/config/model_routes.yml` with backends:
   - `openai` -> `https://api.openai.com/v1`
   - `openrouter` -> `https://openrouter.ai/api/v1`
3. Load provider credentials only from runtime secret files mounted read-only into gate:
   - `${AGENTIC_ROOT}/secrets/runtime/openai.api_key`
   - `${AGENTIC_ROOT}/secrets/runtime/openrouter.api_key`
4. Wire gate outbound through `egress-proxy` (`HTTP_PROXY/HTTPS_PROXY/ALL_PROXY`) and keep local services in `NO_PROXY`.
5. Enrich structured gate logs and response headers with provider metadata (`provider`) while never logging API keys.
6. Add `tests/D5_gate_external_providers.sh`:
   - deterministic missing-key failure path (always runnable),
   - optional live provider validation when `AGENTIC_ENABLE_EXTERNAL_PROVIDER_TESTS=1` and runtime keys are present,
   - proxy-log evidence and secret non-leak checks.

## Consequences
- D5 routing is available without changing agents/UIs: they still target `ollama-gate` only.
- Provider traffic remains auditable and constrained by existing proxy + DOCKER-USER posture.
- Live provider assertions are opt-in to keep baseline CI deterministic when no external credentials are configured.
