# ADR-0135: Managed OpenClaw excludes the standalone `clawhub` CLI

## Status

Accepted - 2026-07-10

## Context

The managed OpenClaw stack already installs the upstream `openclaw` CLI inside the
OpenClaw runtime containers. A follow-up question remained open: should the stack
also ship the separate `clawhub` CLI?

Current repository evidence shows:
- normal catalog workflows already run through native `openclaw` commands,
- managed egress explicitly allowlists `clawhub.ai` and `www.clawhub.ai`,
- `agent doctor` already validates that the deployed OpenClaw runtime can reach the
  ClawHub skills catalog via `openclaw skills search --json --limit 1 calendar`.

Upstream documentation distinguishes two classes of workflow:
- native `openclaw` flows for searching/installing/updating skills and
  ClawHub-hosted plugins inside an OpenClaw workspace,
- standalone `clawhub` flows for authenticated registry operations such as
  `login`, `publish`, `sync`, and package deletion/undeletion.

Those authenticated registry flows are not part of this repository's baseline
operator contract:
- they require extra credentials/tokens,
- they would need explicit provenance tracking and rollout policy,
- they expand the managed runtime surface without helping the default local stack
  workflows.

## Decision

The managed OpenClaw environment intentionally does **not** install the standalone
`clawhub` CLI.

Supported baseline workflows remain:
- `openclaw skills search ...`
- `openclaw skills install <skill-slug>`
- `openclaw skills update ...`
- `openclaw plugins install clawhub:<package>`

Unsupported-by-default managed workflows are the authenticated registry actions
normally handled by the standalone `clawhub` CLI:
- `clawhub login`
- `clawhub publish`
- `clawhub sync`
- `clawhub delete`
- `clawhub undelete`

If a future workflow genuinely requires the standalone `clawhub` binary, it must
be added through a new tracked change with:
- explicit secret handling,
- version provenance in release artifacts,
- operator documentation,
- and regression coverage.

## Consequences

- The OpenClaw containers stay smaller and avoid an unmanaged authenticated
  registry surface.
- Operators should use native `openclaw` commands for normal catalog workflows.
- `agent doctor` continues to validate catalog reachability through native
  `openclaw` search rather than through the standalone `clawhub` binary.
- Regression tests should guard both the explicit exclusion decision and the
  managed ClawHub catalog access path.
