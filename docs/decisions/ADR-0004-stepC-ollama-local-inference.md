# ADR-0004: Step C local-only Ollama inference baseline

## Status
Accepted

## Context
Step C requires Ollama as the shared local inference backend, exposed on host loopback only, with persistent model storage and an automated smoke test for generation.

The implementation must remain compatible with the Step B private network baseline and keep hardening controls enabled.

## Decision
- Extend `compose/compose.core.yml` with an `ollama` service:
  - image `ollama/ollama:latest`,
  - host binding `127.0.0.1:11434:11434`,
  - container healthcheck probing `GET /api/version`,
  - model mount sourced from `OLLAMA_MODELS_DIR` with default `${AGENTIC_ROOT}/ollama/models`.
- Attach Ollama to both `agentic` and `agentic-egress`:
  - `agentic` keeps internal service-to-service access (`http://ollama:11434`),
  - `agentic-egress` is required so Docker can expose the host loopback binding (`127.0.0.1:11434`) while `agentic` remains `internal: true`.
- Add runtime directory provisioning in `deployments/core/init_runtime.sh` for `${AGENTIC_ROOT}/ollama/models`.
- Add generation probe script `deployments/ollama/smoke_generate.sh`:
  - validates `/api/version`,
  - runs `POST /api/generate` against an available local model,
  - exits with explicit `SKIP` when no model is present.
- Add dedicated acceptance tests:
  - `tests/C1_ollama_basic.sh` for API availability, loopback bind, health, and mount-source check,
  - `tests/C2_ollama_generate.sh` for generation smoke and log presence.

## Consequences
- Step C can be validated with `./agent test C` once `./agent up core` is running.
- Operators can reuse an existing model directory by exporting `OLLAMA_MODELS_DIR` before deployment.
- Environments without a pulled model still pass smoke checks with a clear skip message, while preserving strict failure behavior for API/health regressions.
- Because Ollama is dual-homed in Step C, stricter per-service egress filtering for this service should be tightened in later steps when full policy controls are completed.
