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
1. SSH keys are not properly distributed to agent containers
2. Permission issues prevent access to `/home/agent/.ssh/id_ed25519`
3. Some containers missing SSH client entirely (`ssh: not found`)
4. User namespace issues (`No user exists for uid 1000`)

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
- `deployments/optional/git_forge_bootstrap.py`
- Agent container Dockerfiles
- Compose configurations for agent services

## Priority
HIGH - Blocks git-based agent collaboration