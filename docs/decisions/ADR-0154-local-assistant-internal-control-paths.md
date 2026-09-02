# ADR-0154 — Internal control paths for the local assistants

## Status

Accepted — 2026-08-29.

## Context

n8n 2.35.5 creates an Undici `ProxyAgent` for its custom Instance AI model as
soon as `HTTP_PROXY` or `HTTPS_PROXY` is present. That implementation does not
honour `NO_PROXY`, so its otherwise private request to
`http://ollama-gate:11435` is emitted as a Squid `CONNECT` and was denied.

The OpenClaw operator CLI and its managed gateway run in separate containers.
The CLI defaulted to its own `127.0.0.1:18789`, while the gateway intentionally
keeps the upstream listener on loopback inside `openclaw-gateway` and exposes a
TCP forwarder only on the private Docker network. The first gateway health
probe can also enrol the shared CLI device with only `operator.read`; later CLI
commands then require an explicit scope upgrade, but no device yet owns
`operator.pairing` to approve it.

Long-lived n8n sandbox runners have a similar liveness distinction: their HTTP
health endpoint can remain green after their gRPC registration disappeared
from the sandbox API.

## Decision

- Squid permits `CONNECT` only when the destination is exactly
  `ollama-gate:11435` and the source is a private Docker network. All public
  destinations remain governed by the existing domain allowlist.
- The OpenClaw operator container receives
  `OPENCLAW_GATEWAY_URL=ws://openclaw-gateway:8114`, the matching file-backed
  token, and the upstream private-WS opt-in. This exception is limited to the
  isolated Docker network; host publication remains `127.0.0.1` only.
- CLI scope upgrades remain opt-in. `agent openclaw terminal authorize` accepts
  only a named pending request for the same already-paired CLI device and only
  the `operator.read`, `operator.write`, and `operator.pairing` scopes. It
  updates the paired and local token records atomically and logs the action.
- Overflow recovery uses a fresh named session and never resets or deletes the
  failed transcript.
- An explicit n8n sandbox VM start refreshes the deployed VM assets and
  recreates only the stateless runner process, preserving its persistent inner
  Docker data while forcing a new gRPC registration.

## Consequences

The n8n Assistant can use the local model without opening unrestricted egress.
OpenClaw terminal commands reach the managed gateway without public exposure,
and permission expansion remains visible and deliberate. The n8n E2E test now
proves model generation, remote sandbox execution, and workspace deletion; it
also detects a stale runner registration even when container health is green.
