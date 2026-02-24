# ADR-0033: DOCKER-USER Source Scope Defaults to Dual Networks

## Status
Accepted - 2026-02-24

## Context

`ollama` is attached to both `${AGENTIC_NETWORK}` and `${AGENTIC_EGRESS_NETWORK}`.

`deployments/net/apply_docker_user.sh` previously defaulted `AGENTIC_DOCKER_USER_SOURCE_NETWORKS` to `${AGENTIC_NETWORK}` only. In dual-network routing edge cases, traffic sourced from the egress subnet could bypass expected DROP coverage.

## Decision

1. Default `AGENTIC_DOCKER_USER_SOURCE_NETWORKS` to:
   - `${AGENTIC_NETWORK},${AGENTIC_EGRESS_NETWORK}`
2. Keep deduplication and subnet resolution in `apply_docker_user.sh` so custom overrides remain safe.
3. Persist/expose this variable in runtime/onboarding output for deterministic operations.
4. Tighten `doctor` policy checks to require DROP coverage for each configured source subnet.

## Consequences

- Default strict-prod posture now enforces DOCKER-USER source filtering across both internal and egress source subnets.
- Existing operators can still override `AGENTIC_DOCKER_USER_SOURCE_NETWORKS` explicitly.
- Misaligned/stale host firewall rules are detected earlier by `agent doctor`.
