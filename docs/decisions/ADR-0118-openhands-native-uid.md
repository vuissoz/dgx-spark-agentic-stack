# ADR-0118: Keep OpenHands on its native runtime UID

## Status

Accepted

## Context

The stack aligns most services on `${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}` so host-mounted
state and workspaces stay writable in rootless deployments.

OpenHands is an exception. The upstream runtime image and virtualenv are built around the
in-image OpenHands user (`42420:42420`). Running the container as the host UID (`1000:1000`
in `rootless-dev`) leaves the process without a passwd entry, breaks OpenSSH client commands,
and causes `agent doctor` Forgejo SSH probes to fail even though HTTP access still works.

## Decision

`openhands` stays pinned to `42420:42420` in Compose.

To keep the service coherent with the rest of the stack, we still grant it the host runtime
group and maintain explicit SSH ACLs for the OpenHands-managed key material. This preserves:

- access to host-mounted state and workspaces,
- compatibility with the upstream OpenHands runtime layout,
- functional Forgejo SSH access validated by `agent doctor`.

## Consequences

- OpenHands remains the only first-class UI service that does not follow
  `${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}` for its primary UID.
- Runtime/bootstrap code must preserve the SSH readability contract for UID `42420`.
- Future OpenHands image updates should be validated against this native-UID contract before
  considering another host-UID alignment attempt.
