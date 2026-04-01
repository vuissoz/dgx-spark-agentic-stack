# ADR-0098: Forgejo Rootless Container Permission Fix

## Status
Accepted

## Context

The Forgejo service (`optional-forgejo`) was failing to start reliably due to permission issues in the rootless container environment:

1. **Lock file conflicts**: Stale lock files in `${AGENTIC_ROOT}/optional/git/state/queues/common/LOCK` prevented container restart
2. **Permission mismatches**: The rootless container (running as user 1000:1000) couldn't modify files in mounted volumes
3. **Queue directory access**: The container couldn't create/manage lock files in the queues directory
4. **Config directory access**: Permission issues prevented container from modifying configuration files

These issues caused the service to fail with errors like:
- `Failed to create queue "notification-service": unable to lock level db at /var/lib/gitea/queues/common: resource temporarily unavailable`
- `chmod: /var/lib/gitea/custom: Operation not permitted`

## Decision

Implement automatic volume preparation in the UI runtime initialization script to ensure proper permissions before container startup:

1. **Add `prepare_forgejo_volumes()` function** to `deployments/ui/init_runtime.sh`
2. **Set permissive permissions** on queues directory (775) and files (664)
3. **Remove stale lock files** before container startup
4. **Ensure config directory** has correct permissions (775)
5. **Integrate into non-root initialization path** for automatic execution

## Implementation

The fix adds the following function to `deployments/ui/init_runtime.sh`:

```bash
prepare_forgejo_volumes() {
  # Set permissive permissions for Forgejo queues directory to allow container to manage locks
  if [[ -d "${AGENTIC_ROOT}/optional/git/state/queues" ]]; then
    find "${AGENTIC_ROOT}/optional/git/state/queues" -type d -exec chmod 775 {} + 2>/dev/null || true
    find "${AGENTIC_ROOT}/optional/git/state/queues" -type f -exec chmod 664 {} + 2>/dev/null || true
    rm -f "${AGENTIC_ROOT}/optional/git/state/queues/common/LOCK" 2>/dev/null || true
    log "prepared Forgejo queues directory for rootless container"
  fi

  # Ensure config directory has correct permissions
  if [[ -d "${AGENTIC_ROOT}/optional/git/config" ]]; then
    chmod 775 "${AGENTIC_ROOT}/optional/git/config" 2>/dev/null || true
    if [[ -f "${AGENTIC_ROOT}/optional/git/config/app.ini" ]]; then
      chmod 664 "${AGENTIC_ROOT}/optional/git/config/app.ini" 2>/dev/null || true
    fi
    log "prepared Forgejo config directory for rootless container"
  fi
}
```

## Consequences

### Positive
- **Reliable service startup**: Forgejo service starts consistently on fresh starts and restarts
- **Automatic fix**: No manual intervention required
- **Persistent solution**: Works across container recreations and host reboots
- **Backward compatible**: Uses defensive programming with error handling
- **Integrated workflow**: Part of existing agent initialization process

### Trade-offs
- **Permissive permissions**: Uses 775/664 permissions which are more permissive than strict 755/644
- **Automatic cleanup**: Removes lock files automatically, which could theoretically cause issues if files are legitimately locked
- **Non-root specific**: Only applies in non-root scenarios (when EUID ≠ 0)

## Verification

The fix resolves the original doctor check failure:
- ✅ `OK: service 'optional-forgejo' is running and healthy`
- ✅ `OK: service 'optional-forgejo-loopback' is running and healthy`
- ✅ No more "git-forge baseline service 'optional-forgejo' is not running" error
- ✅ Endpoint accessible on http://127.0.0.1:13010/ (HTTP 200)

## Follow-up

- Monitor Forgejo service reliability in production
- Consider adding specific doctor checks for Forgejo permission health
- Document the permission requirements in operator documentation
- Consider adding a `agent forgejo repair` command if similar issues arise with other directories