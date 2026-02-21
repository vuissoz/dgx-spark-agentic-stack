# ADR-0027 — Step F8: Incremental "Time Machine" backups for runtime persistence

## Context

Step F8 requires an operator workflow to:
- create incremental backups of `${AGENTIC_ROOT}` persistence and non-secret operational config,
- list available snapshots with retention policy visibility,
- restore a selected snapshot deterministically with explicit destructive opt-in,
- keep strict exclusion of secrets and private key material.

The existing release snapshot (`agent update`) tracks deployed images/digests, but does not provide a general persistence restore flow for workspaces/state/logs.

## Decision

1. Add `deployments/backups/time_machine.sh` with three actions:
   - `run`: create timestamped snapshot under `${AGENTIC_ROOT}/deployments/backups/snapshots/<snapshot_id>`,
   - `list`: print snapshot inventory with metadata and retention policy,
   - `restore <snapshot_id> [--yes]`: restore selected snapshot with destructive confirmation.
2. Implement incremental storage with `rsync --link-dest` (hardlink-based deduplication between successive snapshots).
3. Capture non-secret config metadata in each snapshot:
   - compose source files + best-effort compose effective config,
   - sanitized `runtime.env`,
   - best-effort `iptables-save` in `strict-prod`.
4. Enforce exclusion rules in backup content:
   - `${AGENTIC_ROOT}/secrets/**`,
   - backup self-storage path,
   - private key/cert patterns (`*.pem`, `*.key`, `*.p12`, `*.pfx`, common SSH private keys).
5. Add retention controls via environment variables:
   - `AGENTIC_BACKUP_KEEP_HOURLY`,
   - `AGENTIC_BACKUP_KEEP_DAILY`,
   - `AGENTIC_BACKUP_KEEP_WEEKLY`.
6. Integrate operator command in `agent`:
   - `agent backup run|list|restore ...`.
7. Add test coverage in `tests/F8_backup_incremental.sh` for incremental behavior, restore behavior, and secret exclusion.

## Consequences

- Operators gain a fast filesystem-level rollback mechanism for persistent state beyond image-digest releases.
- Backup artifacts are auditable (`metadata/backup.json`, `metadata/rsync.changes`, `changes.log`).
- Secret leakage risk is reduced by explicit exclusion + verification checks.
- Restore is intentionally opt-in destructive to avoid accidental data loss.
