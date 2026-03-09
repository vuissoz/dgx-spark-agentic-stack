# ADR-0068: Explicit Goose context limit set to 128k by default

## Status
Accepted

## Context
- Issue `dgx-spark-agentic-stack-ebz` reported ambiguity between:
  - Goose banner display (`0/128k`), and
  - backend model capacity/context settings (`AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW` and `OLLAMA_CONTEXT_LENGTH`, default `262144`).
- Without an explicit Goose client limit, the runtime contract did not document or enforce the value shown in Goose sessions.
- The CDC requires deterministic operator behavior and traceable runtime settings.

## Decision
1. Introduce an explicit runtime variable `AGENTIC_GOOSE_CONTEXT_LIMIT` with default `128000`.
2. Propagate it to `optional-goose` as `GOOSE_CONTEXT_LIMIT`.
3. Persist and expose this value via runtime/profile plumbing:
   - `runtime.env` persistence and `agent profile` output.
4. Enforce compliance and regression checks:
   - `agent doctor` validates presence and numeric bounds of `GOOSE_CONTEXT_LIMIT`,
   - K-suite Goose test validates env propagation and Goose banner display alignment.
5. Keep Goose client limit intentionally decoupled from Ollama backend context defaults.

## Consequences
- Goose now has deterministic client-side context behavior in both strict-prod and rootless-dev.
- Default operator experience is aligned with displayed `128k` usage meter.
- Operators can still override `AGENTIC_GOOSE_CONTEXT_LIMIT` when they explicitly want a different Goose client window.
