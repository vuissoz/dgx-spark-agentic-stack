# ADR-0076: Resolve `latest` deterministically during `agent update`

## Status

Accepted

## Context

The stack intentionally keeps several operator-facing inputs mutable for ease of refresh:
- Docker images declared as `:latest`,
- agent CLI npm specs declared as `@latest`,
- OpenClaw CLI install version declared as `latest`.

Before this change, `agent update` refreshed upstream content and captured a release snapshot afterwards, but it did not materialize every `latest` request into a concrete deployment input before the build/deploy step. This left two gaps:
- the effective deployment config could still show floating aliases,
- local image rebuild stamps did not change when an upstream `latest` moved.

## Decision

`agent update` now performs an explicit resolution phase before build/pull/up:
- supported npm and OpenClaw `latest` inputs are resolved to concrete versions via registry metadata;
- supported Docker image `:latest` references are resolved to repo digests;
- the update uses those resolved values for local image builds and for the compose override applied during pull/up;
- the release snapshot records both the requested mutable value and the resolved concrete value in `latest-resolution.json`.

The operator intent remains unchanged in `runtime.env`; `latest` stays a request policy, not a persisted deployment value.

## Consequences

Positive:
- releases are auditable and rollback stays aligned with a single resolution point,
- local image rebuild stamps now react to upstream movement behind `latest`,
- doctor can detect active releases that still rely on unresolved mutable aliases.

Trade-off:
- `agent update` now depends on registry lookups succeeding for managed mutable inputs.

## Scope

This ADR covers the deterministic resolution performed by `agent update`.
Other paths that can create runtime state without `agent update` keep their current behavior and are expected to be followed by an update for a compliant release snapshot.
