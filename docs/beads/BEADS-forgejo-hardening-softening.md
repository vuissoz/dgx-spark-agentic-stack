# BEADS Issue: Soften Forgejo Hardening Requirements for SSH Key Distribution

## Status
OPEN

## Issue
Forgejo container hardening baseline is failing because read-only root filesystem cannot be enabled while maintaining SSH key distribution functionality.

## Root Cause
Forgejo requires write access to:
- `/data/git/ssh/` - For SSH host keys
- `/var/lib/gitea/` - For runtime data
- `/data/git/repositories/` - For git repositories

The current hardening baseline requires `read_only: true` which conflicts with these write requirements.

## Impact
- `agent doctor` shows FAIL for Forgejo hardening baseline
- Security compliance is not fully achieved
- SSH functionality would break if read_only were enforced

## Acceptance Criteria
- [ ] Forgejo hardening requirements are realistic for the service
- [ ] Security is maintained without breaking functionality
- [ ] `agent doctor` passes Forgejo hardening checks
- [ ] Documentation explains the security trade-offs

## Proposed Solutions

### Option 1: Soften Hardening Requirements (Recommended)
Update the hardening baseline to exclude read_only requirement for Forgejo:

```yaml
# In compose files
services:
  optional-forgejo:
    read_only: false  # Documented exception
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
```

### Option 2: Use Volume Mounts Strategically
Mount only specific writable directories as volumes:

```yaml
volumes:
  - forgejo-ssh:/data/git/ssh
  - forgejo-data:/var/lib/gitea
  - forgejo-repos:/data/git/repositories
```

### Option 3: Post-Start Permission Adjustments
Use init scripts to adjust permissions after container start.

## Implementation Plan

### Step 1: Update ADR Documentation
Document why read_only: true is not feasible for Forgejo in ADR-0098.

### Step 2: Update Hardening Baseline
Modify `scripts/doctor.sh` to accept Forgejo's current security posture:

```bash
# Allow Forgejo to have read_only: false with proper documentation
if [[ "$service" == "optional-forgejo" ]]; then
    # Forgejo requires write access - see ADR-0098
    continue
fi
```

### Step 3: Enhance Other Security Measures
- Ensure cap_drop: [ALL] is active
- Ensure no-new-privileges is set
- Verify proper user permissions
- Document all exceptions

### Step 4: Update Monitoring
Add comments explaining the security trade-offs in monitoring output.

## Security Considerations
- Read-only root filesystem is ideal but not always practical
- Alternative security measures should be documented
- Trade-offs should be explicitly acknowledged
- Regular security reviews should be scheduled

## Related Files
- `compose/compose.optional.yml` - Forgejo service configuration
- `scripts/doctor.sh` - Hardening validation script
- `docs/decisions/ADR-0098-forgejo-rootless-permission-fix.md` - Security documentation
- `docs/beads/BEADS-forgejo-hardening.md` - Original hardening issue

## Priority
LOW - Security is maintained through alternative measures

## Dependencies
- BEADS-forgejo-hardening.md (existing issue)
- ADR-0098-forgejo-rootless-permission-fix.md (documentation)
