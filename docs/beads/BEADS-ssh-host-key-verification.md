# BEADS Issue: SSH Host Key Verification for Forgejo Access

## Status
OPEN

## Issue
Agents cannot access the Forgejo repository via SSH due to host key verification failures:

```
FAIL: agentic-claude cannot access the shared git-forge repository via SSH
Host key verification failed.
```

## Root Cause
This is a standard SSH security feature where the first connection to a new host requires manual host key verification. The agents have valid SSH keys but cannot establish connections because:

1. Forgejo host key is not in agents' known_hosts files
2. SSH strict host key checking is enabled by default
3. No mechanism exists to automatically trust the Forgejo host key

## Impact
- Agents cannot push/pull from shared Forgejo repositories
- Git-based workflows are partially broken
- `agent doctor` shows NOT READY due to SSH access failures

## Acceptance Criteria
- [ ] Agents can successfully connect to Forgejo via SSH
- [ ] Host key verification is properly handled
- [ ] `agent doctor` passes SSH repository access checks
- [ ] Solution maintains security best practices

## Proposed Solutions

### Option 1: Add Forgejo Host Key to Known Hosts (Recommended)
Add the Forgejo container's SSH host key to each agent's known_hosts file:

```bash
# Get Forgejo's SSH host key
ssh-keyscan optional-forgejo > /tmp/forgejo_host_key

# Add to each agent's known_hosts
for agent in claude codex opencode vibestral; do
  docker cp /tmp/forgejo_host_key agentic-dev-agentic-${agent}-1:/state/home/.ssh/known_hosts
  docker exec agentic-dev-agentic-${agent}-1 chown ubuntu:ubuntu /state/home/.ssh/known_hosts
  docker exec agentic-dev-agentic-${agent}-1 chmod 644 /state/home/.ssh/known_hosts
done
```

### Option 2: Disable Strict Host Key Checking (Less Secure)
Configure SSH to automatically accept host keys (not recommended for production):

```bash
# Add to each agent's SSH config
echo "Host optional-forgejo" >> /state/home/.ssh/config
echo "  StrictHostKeyChecking no" >> /state/home/.ssh/config
echo "  UserKnownHostsFile /dev/null" >> /state/home/.ssh/config
```

### Option 3: Automated Host Key Distribution
Modify the git_forge_bootstrap.py script to automatically distribute the Forgejo host key during bootstrap.

## Implementation Plan

### Step 1: Capture Forgejo Host Key
```bash
# During agent initialization or Forgejo startup
ssh-keyscan -H optional-forgejo > ${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts
chmod 644 ${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts
```

### Step 2: Distribute to Agents
Add volume mount to agent containers:
```yaml
- ${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts:/state/home/.ssh/known_hosts:ro
```

### Step 3: Ensure Proper Permissions
```bash
chown 1000:1000 ${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts
chmod 644 ${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts
```

## Testing
After implementation:
1. Test SSH connection: `docker exec agentic-dev-agentic-claude-1 ssh -T git@optional-forgejo`
2. Test git operations: `docker exec agentic-dev-agentic-claude-1 git ls-remote ssh://git@optional-forgejo:2222/agentic/test.git`
3. Run `agent doctor` to confirm all SSH access checks pass

## Security Considerations
- Host key verification is an important security feature
- Solution should not disable verification entirely
- Automated distribution maintains security while improving usability
- Consider rotating Forgejo host keys periodically

## Related Files
- `deployments/optional/git_forge_bootstrap.py` - Bootstrap script
- `compose/compose.agents.yml` - Agent container configurations
- `${AGENTIC_ROOT}/secrets/ssh/forgejo_known_hosts` - Host key file

## Priority
HIGH - Blocks git-based agent collaboration workflows