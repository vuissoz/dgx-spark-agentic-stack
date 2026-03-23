# ADR-0074: OpenClaw layered CLI config with immutable stack policy, validated operator overlay, and writable runtime state

Date: 2026-03-23
Status: Accepted

## Context

The upstream OpenClaw CLI writes a single JSON config file.
In this repository that file previously lived under `${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/openclaw.json`.

Observed problem:

- stack-owned gateway security settings (`gateway.mode`, `gateway.bind`, `gateway.auth.token`, `gateway.tailscale.*`) cohabited with mutable runtime data,
- operator workflows such as `openclaw onboard` and `openclaw agents add` legitimately changed other keys in the same file,
- a direct edit or unexpected upstream write could therefore persist stack-managed security/routing drift in a writable location.

The follow-up issue `dgx-spark-agentic-stack-lhm` requires an explicit three-layer model in `rootless-dev` and `strict-prod`.

## Decision

OpenClaw CLI config is now split into three layers:

1. Immutable stack-owned config:
   - host path: `${AGENTIC_ROOT}/openclaw/config/immutable/openclaw.stack-config.v1.json`
   - mounted read-only in containers at `/config/immutable/openclaw.stack-config.v1.json`
   - owns gateway mode/bind/auth/tailscale posture
2. Validated operator overlay:
   - host path: `${AGENTIC_ROOT}/openclaw/config/overlay/openclaw.operator-overlay.json`
   - mounted writable at `/overlay/openclaw.operator-overlay.json`
   - unknown keys are rejected
   - allowed keys are limited to:
     - `agents.defaults.workspace`
     - `tools.profile`
     - `commands.native`
     - `commands.nativeSkills`
     - `commands.restart`
     - `commands.ownerDisplay`
     - `session.dmScope`
3. Writable runtime state:
   - host path: `${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/openclaw.state.json`
   - plus `.openclaw/` identity/agents metadata and operator workspaces under `${AGENTIC_OPENCLAW_WORKSPACES_DIR}`
   - must not persist immutable or overlay-owned keys

The container image now exposes `openclaw` through a thin wrapper that:

- materializes a derived effective config into tmpfs (`OPENCLAW_CONFIG_PATH=/tmp/openclaw.effective.json`) before each CLI invocation,
- executes the upstream binary from `/etc/agentic/openclaw-real-path`,
- re-extracts only the validated overlay subset and writable state after the command exits.

`openclaw-gateway` uses the same wrapper for read-time materialization, but skips exit-time capture because it is a long-lived service and not the operator write path.

## Consequences

- Stack-managed gateway/security settings are no longer sourced from writable OpenClaw state.
- Operator-safe preferences remain ergonomic: `openclaw onboard`, `openclaw configure`, and `openclaw agents add` still persist useful values, but only through the allowed overlay/state split.
- Direct overlay drift fails closed.
- State drift that reintroduces immutable or overlay-owned keys is stripped on the next managed CLI invocation and flagged by `agent doctor`.

## Validation

- `deployments/core/init_runtime.sh` bootstraps immutable config, overlay, and empty state files.
- `scripts/doctor.sh` validates host layout, container env wiring, and effective runtime reconciliation.
- `tests/K1_openclaw.sh` checks layered bootstrap artifacts.
- `tests/K6_openclaw_cli_dashboard_relay.sh` verifies:
  - overlay persistence for workspace defaults,
  - overlay invalid-key failure,
  - state drift repair for forbidden immutable/overlay keys.
