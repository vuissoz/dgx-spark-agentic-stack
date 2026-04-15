# ADR-0106: Rootless `first-up` grace for initial unresolved `latest`

## Status

Accepted

## Context

`agent update` resolves supported mutable inputs (`:latest`, `@latest`, and the
OpenClaw `latest` install channel) into deterministic digests/versions and records
that proof in `latest-resolution.json`.

The rootless development onboarding path can create an initial `up-auto-bootstrap`
release before the operator has run `agent update`. If that bootstrap release lacks
`latest-resolution.json`, `agent doctor` previously failed even though this was the
first startup path that `agent first-up` is supposed to own.

## Decision

`agent doctor` now delegates release/latest validation to
`deployments/releases/validate_latest_resolution.py`.

The validator keeps deterministic enforcement blocking except for one narrowly
scoped case:

- profile is `rootless-dev`,
- the active release has `reason=up-auto-bootstrap`,
- `latest-resolution.json` is absent,
- mutable `latest` inputs are still present.

That case returns a dedicated warning status. `doctor` reports an actionable warning
and continues, so `agent first-up` does not require a prior `agent update`.

## Consequences

- Fresh `rootless-dev` first startup remains usable even when the bootstrap release
  is not fully traced yet.
- Operators still see the required follow-up: run `agent update` after first
  successful startup to materialize deterministic digests for audit and rollback.
- `strict-prod`, malformed `latest-resolution.json`, and unresolved values in
  `update` releases remain blocking.
