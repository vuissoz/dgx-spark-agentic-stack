# ADR-0143: Report the active OpenClaw context route, not catalog maxima

## Status

Accepted.

## Context

An OpenClaw installation can retain catalog entries for remote providers alongside
the stack-managed local Ollama route. Those entries can advertise larger token
limits than the local session, so using them for operator diagnostics would report
an incorrect effective context window.

## Decision

`agent context show` reports the stack-managed active route explicitly:

- `openclaw_active_provider=custom-ollama-gate-11435`;
- `openclaw_active_model=<AGENTIC_DEFAULT_MODEL>`;
- `openclaw_active_context_window=<AGENTIC_CONTEXT_BUDGET_TOKENS>`.

It also emits `openclaw_catalog_context_note=active_provider_only` to make the
scope machine-readable. The command remains a diagnostic of the platform's local
route; it does not inspect or aggregate arbitrary external provider catalog
metadata.

`agent context set` persists the shared context policy in one runtime env file.
The OpenClaw reconciliation adapter continues to apply the resulting budget to
the managed provider/session metadata when that runtime exists.

## Consequences

- Operators receive the actual local context policy even if an OpenClaw catalog
  has a larger remote Codex entry.
- The catalog is preserved rather than destructively pruned.
- `tests/F28_context_command.sh` covers both persistence and the unambiguous
  diagnostic contract; `tests/K14_openclaw_context_reconcile.sh` covers adapter
  reconciliation.
