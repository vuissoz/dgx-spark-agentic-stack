# BEADS Issue: Forgejo Container Hardening Baseline Failure

## Status
OPEN

## Issue
Forgejo container fails security hardening baseline checks in `agent doctor`:

```
FAIL: 9e33cdd9c6a7: readonly rootfs is not enabled
FAIL: 9e33cdd9c6a7: cap_drop does not include ALL
FAIL: 9e33cdd9c6a7: no-new-privileges is missing
WARN: service 'optional-forgejo' hardening baseline failed
```

## Root Cause
The `optional-forgejo` service in `compose/compose.ui.yml` lacks security hardening:
1. No `read_only: true` filesystem
2. Missing `cap_drop: [ALL]` capability dropping
3. No `security_opt: ["no-new-privileges:true"]` security option
4. Forgejo rootless container may require specific exceptions

## Impact
- Security compliance failures prevent `agent doctor` from passing
- Container has broader privileges than necessary
- Potential security vulnerabilities in production

## Acceptance Criteria
- [ ] Forgejo container runs with readonly root filesystem where possible
- [ ] Appropriate capabilities are dropped (cap_drop: [ALL])
- [ ] no-new-privileges security option is enabled
- [ ] Necessary exceptions are documented and minimized
- [ ] `agent doctor` passes container hardening checks
- [ ] Service remains functional with hardening applied

## Related Files
- `compose/compose.ui.yml` - Forgejo service definition
- `deployments/ui/init_runtime.sh` - Runtime initialization
- Doctor hardening checks in agent validation

## Technical Notes
- Rootless containers have different hardening requirements
- Forgejo may need write access to specific directories
- Need to balance security with functionality
- May require tmpfs mounts for writable areas

## Priority
MEDIUM - Security improvement, not blocking current functionality