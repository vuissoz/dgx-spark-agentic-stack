# ADR-0155: Bridge OpenHands V1 Git Changes through the same-origin app server

## Status

Accepted

## Context

In `rootless-dev`, OpenHands V1 conversations use an in-container
`ProcessSandbox` agent server. The existing browser-facing conversation URL is
correctly bridged through the app server, but the OpenHands 1.3 Changes panel
constructs direct runtime URLs for `/api/git/changes/<path>` and
`/api/git/diff/<path>`.

For a process runtime these direct URLs resolve to the app-server origin or to
an unexposed loopback port. The UI therefore receives HTML or another
non-array response and displays `Invalid response from runtime - runtime may
be unavailable`, even though the conversation runtime is healthy.

## Decision

1. Add same-origin V1 endpoints under
   `/api/v1/app-conversations/{conversation_id}/git/{changes,diff}` in the
   mounted OpenHands listener patch.
2. Resolve the real agent-server URL and session key server-side from V1
   start-task metadata, as already done for the event and WebSocket bridges.
3. Restrict bridged paths to `/workspace/`, return explicit HTTP errors for
   unavailable or malformed runtime responses, and never return session keys.
4. Patch the version-pinned OpenHands 1.3 compiled frontend bundle at image
   build time so its V1 Changes panel calls these same-origin endpoints. The
   patch fails the image build if the expected upstream bundle signature is
   absent or ambiguous.
5. Cover the bridge with an end-to-end H2 smoke test using a temporary Git
   repository in the mounted OpenHands workspace.

## Consequences

- The Changes and Diff panes work for V1 rootless process sandboxes without
  exposing dynamic runtime ports to the browser or host.
- Build-time signature checking makes an upstream frontend change visible
  during `agent update` rather than silently reintroducing the failure.
- The local patch must be reviewed when upgrading the OpenHands base image.
