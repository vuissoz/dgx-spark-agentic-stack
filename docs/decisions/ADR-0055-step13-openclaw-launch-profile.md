# ADR-0055: Step 13 OpenClaw launch-inspired profile v1 and runtime contract enforcement

## Status
Accepted

## Context
Step 13 (`dgx-spark-agentic-stack-ik6`) requires a complete OpenClaw implementation inspired by the observable `ollama launch openclaw` contract, with:
- a versioned integration profile used during bootstrap,
- runtime enforcement for auth/endpoints/sandbox policy,
- end-to-end tests covering setup, nominal flow, unauthorized refusal, and contract drift.

The previous implementation exposed OpenClaw endpoints and sandbox forwarding but lacked a versioned runtime profile contract consumed at bootstrap/startup.

## Decision
- Introduce a versioned OpenClaw integration profile template:
  - `examples/optional/openclaw.integration-profile.v1.json`
- Bootstrap profile files into runtime config:
  - `${AGENTIC_ROOT}/optional/openclaw/config/integration-profile.v1.json`
  - `${AGENTIC_ROOT}/optional/openclaw/config/integration-profile.current.json`
- Wire profile paths in Compose env:
  - `OPENCLAW_PROFILE_FILE=/config/integration-profile.current.json`
  - `OPENCLAW_SANDBOX_PROFILE_FILE=/config/integration-profile.current.json`
- Extend optional runtime service to:
  - load and validate profile schema at startup (OpenClaw and sandbox modes),
  - enforce required env variables and proxy/allowlist policy from profile,
  - expose profile/capabilities endpoints (`/v1/profile`, `/v1/capabilities`),
  - support launch-inspired endpoint aliases (`/v1/dm/send`, `/v1/webhooks/channels/dm`, `/v1/sandbox/tools/execute`).
- Extend validations:
  - `agent up optional` validates OpenClaw profile presence/schema before deploy,
  - `agent doctor` validates profile file, endpoint contract minima, and OpenClaw profile env wiring.
- Extend tests:
  - `tests/K1_openclaw.sh` now validates bootstrap profile, nominal/unauthorized/alias flows, and OpenClaw drift detection.
  - drift invariants for source `openclaw` were expanded in `scripts/ollama_drift_watch.sh`.

## Consequences
- OpenClaw optional module now has an explicit versioned contract artifact that operators can audit and diff.
- Runtime starts fail-closed when required profile/env/policy conditions are missing.
- Drift detection is stricter for OpenClaw upstream contract changes.
