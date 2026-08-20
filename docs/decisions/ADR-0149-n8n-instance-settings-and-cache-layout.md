# ADR-0149 — n8n instance settings and writable cache layout

## Status

Accepted.

## Context

Recent `n8nio/n8n:latest` images reserve `/home/node/.n8n/config` for an
instance settings file. The optional stack mounted a host directory at that
path, causing an `EISDIR` restart loop. The image also generates static assets
under `/home/node/.cache`, which conflicts with the required read-only root
filesystem unless that narrow path is writable.

Existing broken deployments can contain a root-owned `data/config` directory
created by Docker as the former nested bind-mount target.

## Decision

- Persist the whole `/home/node/.n8n` directory with the existing `data` bind
  mount and do not add a nested mount at `/home/node/.n8n/config`.
- Preserve a legacy `data/config` directory under a timestamped recoverable
  backup name before n8n starts, then let n8n create its settings file.
- Repair only the scoped n8n runtime tree when legacy root ownership blocks a
  rootless migration.
- Keep the container root filesystem read-only and provide only
  `/home/node/.cache` as a mode `1777` tmpfs.
- Resolve the dynamic nginx upstream through Docker DNS (`127.0.0.11`) so the
  loopback proxy remains stable across container recreation.

## Consequences

Workflow and credential state remains in the persistent data root. Legacy
configuration directories are retained for recovery rather than deleted. A
runtime regression test verifies the mount type, late asset generation,
loopback endpoint, hardening, and stop/start lifecycle.
