# BEADS Issue: Agent SSH Key Distribution Failure

## Status
OPEN

## Issue
Agents cannot access SSH keys to communicate with Forgejo repository, causing `agent doctor` failures:

```
FAIL: agentic-claude SSH key is missing or not readable
FAIL: agentic-claude cannot access the shared git-forge repository via SSH
```

## Root Cause
1. **Volume mount path mismatch**: SSH keys are mounted to `/home/agent/.ssh/` but agents' home directory is `/state/home/`
2. **Git config mismatch**: Git is configured to look for SSH keys at `/state/home/.ssh/id_ed25519` but volume mounts point to `/home/agent/.ssh/`
3. **Permission issues**: Directory permissions (700) may prevent container access despite UID matching
4. **Missing SSH client**: Some containers don't have SSH client installed (`ssh: not found`)
5. **User namespace issues**: Some containers report `No user exists for uid 1000`

## Detailed Analysis

### Volume Mount Configuration
Current volume mounts in `compose/compose.agents.yml`:
```yaml
- ${AGENTIC_ROOT:-/srv/agentic}/secrets/ssh/claude:/home/agent/.ssh:ro
```

But agent containers have `HOME: /state/home`, so the SSH keys should be mounted to `/state/home/.ssh/` instead.

### Git Configuration
The `git_forge_bootstrap.py` generates git config with:
```ini
[core]
    sshCommand = ssh -i /state/home/.ssh/id_ed25519 -F /dev/null
```

This creates a mismatch between where git expects the keys (`/state/home/.ssh/`) and where they're actually mounted (`/home/agent/.ssh/`).

### Required Fix
Change volume mounts from:
```yaml
- ${AGENTIC_ROOT:-/srv/agentic}/secrets/ssh/claude:/home/agent/.ssh:ro
```

To:
```yaml
- ${AGENTIC_ROOT:-/srv/agentic}/secrets/ssh/claude:/state/home/.ssh:ro
```

This needs to be done for all agents: claude, codex, opencode, vibestral.

## Impact
- Agents cannot push/pull from shared Forgejo repositories
- Git-based workflows are broken
- `agent doctor` shows NOT READY due to SSH failures

## Acceptance Criteria
- [ ] All agents have valid SSH keys in their containers
- [ ] SSH keys have correct permissions (600)
- [ ] Agents can successfully clone/push to Forgejo via SSH
- [ ] `agent doctor` passes SSH-related checks
- [ ] SSH client is available in all agent containers

## Related Files
- `deployments/optional/git_forge_bootstrap.py` - Generates git config with SSH key paths
- `compose/compose.agents.yml` - Contains volume mount configurations (lines 70, 150, 231, 311)
- Agent container Dockerfiles - May need SSH client installation

## Specific Changes Required

### 1. Fix Volume Mount Paths in `compose/compose.agents.yml`
```bash
# Line 70: claude
sed -i 's|secrets/ssh/claude:/home/agent/.ssh:ro|secrets/ssh/claude:/state/home/.ssh:ro|' compose/compose.agents.yml

# Line 150: codex
sed -i 's|secrets/ssh/codex:/home/agent/.ssh:ro|secrets/ssh/codex:/state/home/.ssh:ro|' compose/compose.agents.yml

# Line 231: opencode
sed -i 's|secrets/ssh/opencode:/home/agent/.ssh:ro|secrets/ssh/opencode:/state/home/.ssh:ro|' compose/compose.agents.yml

# Line 311: vibestral
sed -i 's|secrets/ssh/vibestral:/home/agent/.ssh:ro|secrets/ssh/vibestral:/state/home/.ssh:ro|' compose/compose.agents.yml
```

### 2. Ensure SSH Client is Available
Some containers (like comfyui) report `ssh: not found`, indicating missing SSH client.

### 3. Verify Directory Permissions
Ensure host directories have appropriate permissions for container access:
```bash
chmod 755 ${AGENTIC_ROOT}/secrets/ssh
chmod 755 ${AGENTIC_ROOT}/secrets/ssh/*/
```

## Testing
After applying fixes:
1. Restart agent containers
2. Verify SSH keys are accessible: `docker exec <container> ls -la /state/home/.ssh/`
3. Test git operations: `docker exec <container> git ls-remote ssh://git@optional-forgejo:2222/agentic/eight-queens-agent-e2e.git`
4. Run `agent doctor` to confirm SSH access checks pass

## Priority
HIGH - Blocks git-based agent collaboration