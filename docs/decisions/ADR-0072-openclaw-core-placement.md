# ADR-0072: OpenClaw moved from optional to core

## Status

Accepted - 2026-03-22

## Context

The `dgx-spark-agentic-stack-qcy` follow-up requires OpenClaw to start with `./agent up core` in `rootless-dev` and `strict-prod`, without relying on `AGENTIC_OPTIONAL_MODULES=openclaw`.

The previous placement under `compose.optional.yml` created three mismatches:
- operator workflows (`agent openclaw`, dashboard, relay, gateway) depended on an optional opt-in even though they are part of the main stack experience,
- runtime layout used `${AGENTIC_ROOT}/optional/openclaw/...`, while the target convention is `${AGENTIC_ROOT}/openclaw/...`,
- update/doctor/rollback logic had to treat OpenClaw as an exception instead of a core service.

## Decision

OpenClaw is promoted into `compose/compose.core.yml` as four core services:
- `openclaw`
- `openclaw-gateway`
- `openclaw-sandbox`
- `openclaw-relay`

The persistent runtime layout moves to:
- `${AGENTIC_ROOT}/openclaw/config`
- `${AGENTIC_ROOT}/openclaw/state`
- `${AGENTIC_ROOT}/openclaw/logs`
- `${AGENTIC_ROOT}/openclaw/relay/{state,logs}`
- `${AGENTIC_ROOT}/openclaw/sandbox/state`
- `${AGENTIC_OPENCLAW_WORKSPACES_DIR}` with default `${AGENTIC_ROOT}/openclaw/workspaces`

`compose.optional.yml` keeps only the remaining optional modules (`mcp`, `pi-mono`, `goose`, `portainer`).

## Consequences

- `agent up core` now brings up the full OpenClaw control plane.
- `agent stop openclaw`, `agent logs openclaw`, `agent doctor`, and local image builds target the core services.
- onboarding/bootstrap generates OpenClaw runtime secrets and profile files as part of core preparation.
- optional-module request files no longer apply to OpenClaw.
