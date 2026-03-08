# ADR-0066: `optional-pi-mono` local provider bootstrap for `pi` CLI

## Status
Accepted

## Context
- In `rootless-dev`, `pi` inside `optional-pi-mono` could fail with:
  - `401 ... "invalid x-api-key"`
- The `pi` CLI runtime did not have a managed local provider config (`~/.pi/agent/models.json`, `~/.pi/agent/settings.json`), unlike other agent CLIs that already had explicit local bootstrap adapters.
- Without this adapter, `pi` could fall back to a cloud provider path even when stack defaults exported local gate variables.

## Decision
1. Add a dedicated `pi` bootstrap adapter in `agent-entrypoint` for `optional-pi-mono`:
   - reconcile `~/.pi/agent/models.json` with provider `ollama`,
   - enforce provider endpoint `http://ollama-gate:11435/v1`,
   - enforce API mode `openai-completions`,
   - ensure the default model is present in provider models.
2. Reconcile `~/.pi/agent/settings.json`:
   - `defaultProvider=ollama`,
   - `defaultModel=${AGENTIC_DEFAULT_MODEL}`.
3. Pin `optional-pi-mono` environment defaults to local contract values:
   - `OPENAI_BASE_URL=http://ollama-gate:11435/v1`,
   - `OPENAI_API_KEY=ollama`,
   - matching `ANTHROPIC_*` placeholder key alignment (`ollama`).
4. Extend compliance/test coverage:
   - `doctor`: verify `~/.pi/agent` config exists and points to local provider contract.
   - `K4_pi_mono`: verify env and reconciled `pi` config payload.

## Consequences
- `pi-mono` behaves deterministically in local stack mode and no longer depends on implicit cloud defaults.
- Regression is caught by both `doctor` and K tests before operator runtime usage.
