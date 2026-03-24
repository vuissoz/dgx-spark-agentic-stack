# ADR-0081: OpenClaw Control UI Build and Provider Bridge

## Status

Accepted - 2026-03-24

## Context

The stack exposed `openclaw-gateway` on `127.0.0.1:18789`, but the optional image
papered over missing upstream Control UI assets by generating a placeholder
`dist/control-ui/index.html`. That made the port reachable while failing to serve
the actual upstream browser UI.

At the same time, upstream OpenClaw already supports Telegram, Slack, Discord,
and WhatsApp channel integrations, but this stack only provisioned the local
relay/webhook skeleton. File-backed secrets managed by the stack were not being
bridged into OpenClaw's channel configuration, so providing a bot token in the
stack runtime had no effect.

## Decision

1. Build the real OpenClaw Control UI from the source tag matching the
   installed CLI version during the optional image build, then copy the resulting
   `dist/control-ui/*` tree into the installed package path.
2. Remove the stack-generated fallback gateway page. Missing UI assets now
   become a packaging/build problem rather than a fake-success runtime.
3. Introduce a dedicated `openclaw-provider-bridge` service that:
   - consumes stack-managed secret files,
   - writes a deterministic bridge config layer under
     `${AGENTIC_ROOT}/openclaw/config/bridge/openclaw.provider-bridge.json`,
   - exposes bridge health/status in
     `${AGENTIC_ROOT}/openclaw/state/provider-bridge-status.json`,
   - seeds upstream OpenClaw channel config for Telegram, Slack, and Discord,
   - optionally bootstraps the WhatsApp plugin when explicitly enabled.
4. Extend the layered OpenClaw config contract from
   `immutable + overlay + state` to `immutable + provider-bridge + overlay + state`.
5. Keep all OpenClaw-facing services loopback-only. Provider secrets remain
   file-backed outside git and are exported only inside the relevant containers
   through the managed wrapper.

## Consequences

Positive:

- `127.0.0.1:18789` serves the real upstream browser UI again.
- Clean rebuilds reconstitute the same UI and provider bridge behavior.
- Telegram/Slack/Discord become functional through upstream OpenClaw channel
  support without exposing a new public ingress.
- Provider-derived config is deterministic and auditable, rather than hidden in
  mutable operator state.

Trade-offs:

- Optional image builds now require a source checkout/build step for the Control UI.
- The OpenClaw config layering model is slightly more complex.
- WhatsApp remains operator-assisted because QR login is an intentional manual step.
