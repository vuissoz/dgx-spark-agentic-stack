# BEADS Issue: ComfyUI and OpenHands SSH Configuration

## Status
OPEN

## Issue
ComfyUI and OpenHands services cannot access SSH keys for Forgejo repository access:

```
FAIL: comfyui SSH key is missing or not readable
FAIL: comfyui SSH public key is missing or not readable
ssh -i  -F /dev/null: 1: ssh: not found

FAIL: openhands SSH key is missing or not readable
FAIL: openhands SSH public key is missing or not readable
Warning: Identity file -F not accessible: No such file or directory.
```

## Root Cause
1. **Missing SSH Volume Mounts**: Unlike the main agents, ComfyUI and OpenHands don't have SSH key volume mounts configured
2. **Missing SSH Client**: ComfyUI container doesn't have SSH client installed (`ssh: not found`)
3. **Different Configuration**: These services may use different authentication methods or not need SSH access

## Impact
- ComfyUI and OpenHands cannot access Forgejo repositories via SSH
- Incomplete git-based workflow support
- `agent doctor` shows NOT READY due to SSH access failures

## Acceptance Criteria
- [ ] Determine if ComfyUI and OpenHands need SSH access to Forgejo
- [ ] If needed, configure SSH volume mounts similar to main agents
- [ ] Ensure SSH client is available in containers that need it
- [ ] `agent doctor` passes SSH checks for these services (or document why they're not needed)

## Investigation Required

### Step 1: Determine SSH Requirements
- Check if ComfyUI and OpenHands actually need SSH access to Forgejo
- Review their git configuration and usage patterns
- Check if they use HTTP access instead of SSH

### Step 2: Check Current Configuration
```bash
# Check ComfyUI git config
docker exec agentic-dev-comfyui-1 cat /.openhands/home/.gitconfig 2>/dev/null || echo "No git config found"

# Check OpenHands git config
docker exec agentic-dev-openhands-1 cat /.openhands/home/.gitconfig 2>/dev/null || echo "No git config found"
```

### Step 3: Verify SSH Client Availability
```bash
# Check if SSH client is installed
docker exec agentic-dev-comfyui-1 which ssh || echo "SSH not found"
docker exec agentic-dev-openhands-1 which ssh || echo "SSH not found"
```

## Potential Solutions

### Option 1: Add SSH Volume Mounts (If Needed)
If ComfyUI/OpenHands need SSH access, add volume mounts similar to main agents:

```yaml
# For ComfyUI (if needed)
- ${AGENTIC_ROOT}/secrets/ssh/comfyui:/home/comfyui/.ssh:ro

# For OpenHands (if needed)
- ${AGENTIC_ROOT}/secrets/ssh/openhands:/home/openhands/.ssh:ro
```

### Option 2: Configure HTTP Access
If SSH isn't needed, ensure git is configured for HTTP access:

```ini
[remote "origin"]
    url = http://optional-forgejo:3000/agentic/repo.git
    insteadOf = ssh://git@optional-forgejo:2222/agentic/repo.git
```

### Option 3: Install SSH Client
For containers that need SSH but don't have the client:

```dockerfile
# In ComfyUI Dockerfile
RUN apt-get update && apt-get install -y openssh-client && rm -rf /var/lib/apt/lists/*
```

## Implementation Steps

### 1. Investigate Current Usage
- Check existing git operations in ComfyUI/OpenHands
- Determine if SSH access is actually required
- Review error logs for actual usage patterns

### 2. Decide on Approach
- **If SSH needed**: Add volume mounts and ensure SSH client available
- **If HTTP sufficient**: Configure git to use HTTP and remove SSH requirements
- **If not needed**: Update doctor checks to reflect this

### 3. Implement Solution
- Update compose files with appropriate volume mounts
- Modify Dockerfiles if SSH client installation needed
- Update git configuration if switching to HTTP

### 4. Test and Validate
```bash
# Test ComfyUI access
docker exec agentic-dev-comfyui-1 git ls-remote http://optional-forgejo:3000/agentic/test.git

# Test OpenHands access
docker exec agentic-dev-openhands-1 git ls-remote http://optional-forgejo:3000/agentic/test.git

# Run doctor to confirm
agent doctor
```

## Related Files
- `compose/compose.ui.yml` - ComfyUI and OpenHands service definitions
- `deployments/images/comfyui/Dockerfile` - ComfyUI container image
- `deployments/images/openhands/Dockerfile` - OpenHands container image
- `${AGENTIC_ROOT}/secrets/ssh/{comfyui,openhands}` - SSH key directories

## Priority
MEDIUM - Need to determine if SSH access is actually required before implementing fixes