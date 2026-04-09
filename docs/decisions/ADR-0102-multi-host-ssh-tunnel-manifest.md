# ADR-0102: Multi-host SSH tunnel generation from a single manifest

## Context

Remote access to this stack is intentionally limited to:

- Tailscale to reach the host,
- SSH local forwarding to reach host-loopback services,
- no direct public bind widening.

The repository documented manual `ssh -L` examples in multiple places, which created two recurring problems:

1. drift between docs and actual `*_HOST_PORT` runtime values,
2. no operable path for non-shell clients such as iPhone.

## Decision

Introduce a stack-owned tunnel manifest plus a generator:

- source of truth: `scripts/tunnel_manifest.json`,
- implementation: `scripts/tunnel_matrix.py`,
- operator entrypoint: `./agent tunnel ...`.

The generator resolves runtime host ports from environment/runtime state, lists the known loopback-published surfaces, validates which ones are currently reachable, and emits client artifacts for:

- Linux,
- macOS,
- Windows PowerShell,
- iPhone via OpenSSH-style config snippet rather than a shell script.

## Consequences

- Remote-access scripts no longer duplicate port knowledge across README snippets.
- iPhone gets an explicit supported artifact without pretending that generic shell scripting exists there.
- New loopback-published surfaces must be added once in the tunnel manifest instead of being hand-copied into multiple docs.
