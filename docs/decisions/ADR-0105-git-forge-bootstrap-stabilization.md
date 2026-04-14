# ADR-0105: Git Forge Bootstrap Stabilization

## Status
Accepted

## Context

Rootless-dev Forgejo bootstrap had converged enough to start, but the runtime
contract was still split across Compose mounts, generated Git config, and doctor
checks. The visible failures were:

- agents with more than one possible SSH path;
- `known_hosts` written under one filename but probed under another convention;
- optional agents without a mounted SSH directory;
- existing Forgejo admin accounts blocked by `must-change-password`;
- doctor relying on bootstrap state that did not describe the SSH contract.

## Decision

Forgejo bootstrap now owns the single source of truth for managed Git access:

- each service has one canonical in-container SSH directory;
- per-account SSH files are mounted read-only from
  `${AGENTIC_ROOT}/secrets/ssh/<account>`;
- `known_hosts` is always named `known_hosts`;
- the shared `${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts` file is refreshed
  from the live Forgejo SSH host key before per-account files are copied;
- generated Git config uses the same key and `known_hosts` paths through
  `core.sshCommand`;
- bootstrap clears Forgejo `must-change-password` for managed users before any
  API-based organization/repository reconciliation;
- `git-forge-bootstrap.json` records the compose project, reference repository
  policy, and SSH path contract.

## Consequences

`./agent doctor` can now validate the same contract that Compose and bootstrap
materialize. The rootless-dev `first-up` path has an integration gate that runs
through baseline startup, Forgejo bootstrap state creation, and doctor.
