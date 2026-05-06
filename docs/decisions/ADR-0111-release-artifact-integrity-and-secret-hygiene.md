# ADR-0111: Release Artifact Integrity And Secret Hygiene

## Status

Accepted

## Context

Release snapshots already captured the effective Compose configuration, image digests,
runtime environment excerpts, and health state under
`${AGENTIC_ROOT}/deployments/releases/<release_id>`.

That gave rollback traceability, but two security gaps remained:

1. No immutable checksum manifest proved that the release artifacts themselves had not
   been modified after capture.
2. No generic compliance check asserted that plaintext contents from
   `${AGENTIC_ROOT}/secrets` had not leaked into release artifacts.

Given the CDC priority on traceability and secret handling, those checks must be part
of the release contract, not left to ad hoc inspection.

## Decision

Each release snapshot is now sealed with `artifact-integrity.json`, generated from the
full regular-file contents of the release directory except the integrity file itself.

`agent doctor` now validates:

- the presence and schema of that integrity manifest,
- checksum coherence between the manifest and the actual release files,
- coverage of all release artifacts by the manifest,
- absence of plaintext secret values from `${AGENTIC_ROOT}/secrets` inside scanned
  release artifacts,
- absence of obvious private key material markers in release artifacts.

Legacy releases without `artifact-integrity.json` remain a non-blocking warning in
`doctor`; the remediation path is `./agent update`, which reseals the active release.

## Consequences

- Release tampering becomes detectable before rollback/compliance operations continue.
- Secret leakage into release artifacts becomes a first-class compliance failure.
- `agent update` and auto-snapshot flows must reseal the release after copying any
  late-added artifacts such as `latest-resolution.json`.
