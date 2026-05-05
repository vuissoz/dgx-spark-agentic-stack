# ADR-0102 — Align `agentic-hermes` with the upstream `ollama launch hermes` contract

## Status
Accepted

## Context
Ollama now publishes an official Hermes integration guide at `docs/integrations/hermes.mdx` and exposes `ollama launch hermes`.

The upstream observable contract has two distinct layers:
- a launch-level contract (`ollama launch hermes`, `hermes gateway setup`, `hermes setup`);
- a manual Hermes setup flow that still points Hermes at an OpenAI-compatible custom endpoint (`http://127.0.0.1:11434/v1`).

The repository previously classified Hermes as `adapter-internal` and rewrote its managed config destructively, including `OPENAI_BASE_URL` and an inline `model.api_key`.

## Decision
1. Reclassify Hermes as `launch-supported` in the Ollama integration matrix and drift-watch coverage.
2. Keep the managed runtime bootstrap aligned with the upstream manual setup contract:
   - `model.provider: custom`
   - `model.base_url: http://ollama-gate:11435/v1`
   - `model.default: <AGENTIC_DEFAULT_MODEL>`
3. Stop storing the managed API key inline in `config.yaml`; keep it in `~/.hermes/.env` only.
4. Stop persisting `OPENAI_BASE_URL` in `~/.hermes/.env` because `config.yaml` already pins the endpoint.
5. Preserve non-managed top-level sections of `config.yaml` and non-managed lines in `.env` across bootstrap reconciliation.
6. Add the `web` toolset to the managed Hermes toolset set for launch parity.

## Consequences
- Hermes now participates in upstream Ollama contract drift detection like the other launch-backed integrations.
- Runtime behavior stays compatible with the official Hermes manual setup path instead of inventing a stack-only provider schema.
- Operator-local Hermes settings outside the stack-managed sections survive restarts.
