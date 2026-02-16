# Runbook: Host Network Rollback (DOCKER-USER)

## Scope
- Changes applied by `sudo` on host firewall for stack egress enforcement.
- Current target: `DOCKER-USER` + `${AGENTIC_DOCKER_USER_CHAIN:-AGENTIC-DOCKER-USER}`.

## Apply (creates backup)

```bash
./agent net apply
```

Expected output includes:
- `backup_id=<id>`

Each apply writes:
- backup snapshot: `${AGENTIC_ROOT}/deployments/host-net/backups/<id>/iptables-save.rules`
- audit lines in `${AGENTIC_ROOT}/deployments/changes.log`

## Rollback

```bash
./agent rollback host-net <backup_id>
```

This restores the `DOCKER-USER`/agentic chain state from the selected backup.

## Validate

```bash
./agent doctor
./agent test B
```
