# BEADS Issue: Add SSH Clients to UI Services for Forgejo Access

## Status
OPEN

## Issue
UI services (comfyui, openclaw, openhands) cannot access the Forgejo repository via SSH because they lack SSH clients in their containers. This prevents them from participating in git-based workflows.

## Root Cause
These services use minimal container images that don't include SSH clients:
- comfyui: Based on Python/ML images without SSH
- openclaw: Minimal container without SSH client
- openhands: Minimal container without SSH client

## Impact
- These services cannot push/pull from shared Forgejo repositories
- Git-based collaboration workflows are partially broken for UI services
- `agent doctor` shows FAIL for SSH access checks

## Acceptance Criteria
- [ ] comfyui container includes SSH client
- [ ] openclaw container includes SSH client  
- [ ] openhands container includes SSH client
- [ ] All UI services can access Forgejo via SSH
- [ ] `agent doctor` passes SSH checks for UI services
- [ ] Solution maintains container security

## Proposed Solutions

### Option 1: Add SSH Client to Container Images (Recommended)
Modify the Dockerfiles or compose configurations to install SSH clients:

```dockerfile
# For comfyui
RUN apt-get update && apt-get install -y openssh-client && rm -rf /var/lib/apt/lists/*

# For openclaw/openhands
RUN apk add --no-cache openssh-client
```

### Option 2: Use Multi-stage Builds
Create optimized images with SSH clients only in build stage.

### Option 3: Sidecar Containers
Add sidecar containers with SSH clients for git operations.

## Implementation Plan

### Step 1: Identify Base Images
- Check current Dockerfiles/compose configs for each service
- Determine appropriate package manager (apt, apk, etc.)

### Step 2: Add SSH Client Installation
```dockerfile
# Example for comfyui (Debian-based)
RUN apt-get update && \
    apt-get install -y openssh-client && \
    rm -rf /var/lib/apt/lists/*
```

### Step 3: Add Known Hosts Configuration
Ensure forgejo_known_hosts is available in each container:
```yaml
# In compose files
- ${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts:/etc/ssh/ssh_known_hosts:ro
```

### Step 4: Test SSH Access
```bash
docker exec comfyui-container ssh -T -p 2222 git@optional-forgejo
docker exec comfyui-container git ls-remote ssh://git@optional-forgejo:2222/agentic/test.git
```

### Step 5: Update Doctor Script
Ensure doctor script properly detects SSH clients in UI containers.

## Security Considerations
- SSH clients should be minimal (no server components)
- Use read-only mounts for known_hosts
- Consider removing SSH client after build if not needed at runtime
- Document the security implications

## Related Files
- `compose/compose.ui.yml` - UI service configurations
- `Dockerfile` files for each service
- `scripts/doctor.sh` - Health check script
- `${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts` - Host key file

## Priority
MEDIUM - Blocks git workflows for UI services but not critical path

## Dependencies
- BEADS-ssh-host-key-verification.md (resolved)
