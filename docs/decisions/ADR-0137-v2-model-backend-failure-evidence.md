# ADR-0137: Model-backend-failure evidence producer for v2

Date: 2026-07-09

Status: accepted

## Context

The v2 evaluator now consumes machine evidence for bootstrap-doctor and context-isolation. The next P0 walking-skeleton journey is model-backend-failure: a backend outage must not become a silent success, and agents must not bypass the broker to reach model backends directly.

The deployed v2 ModelBroker does not exist yet, so this slice must provide a local policy oracle rather than runtime proof.

## Decision

Add `scripts/produce_v2_model_backend_failure_evidence.py`.

The producer simulates:

- a primary backend that is unavailable;
- a broker decision that is either an actionable refusal or an explicit fallback;
- a negative direct-backend-access probe that must be refused.

The producer returns `pass` only when backend failure is explicit and actionable and direct backend access is refused. Test hooks intentionally allow direct access or silent success to prove those paths fail closed.

## Consequences

The evidence is marked as `local_simulated_broker_policy`. It proves the broker policy oracle and evaluator artifact shape, not deployed ModelBroker behavior.

Future runtime work must supplement this with live broker/backend failure injection, direct network refusal checks, usage accounting, and durable correlated audit evidence.
