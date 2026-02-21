# ADR-0021: DOCKER-USER Policy Refresh and Source-Subnet Scoping

## Status
Accepted (2026-02-21)

## Context

During strict-prod host validation, three issues were observed:

1. `agent rollback host-net <backup_id>` could fail when restoring `iptables-save` rules containing quoted arguments.
2. After `agent update` or `agent rollback all`, recreated containers could get new IPs while host `DOCKER-USER` rules still referenced old IPs.
3. Applying DROP rules to both internal and egress subnets over-restricted east-west traffic and broke internal service paths used by the test campaign (`openwebui -> ollama-gate`, `toolbox -> qdrant`, optional module checks).

## Decision

1. Host-net rollback parsing:
   - Restore `iptables-save` `-A` rules using shell-evaluated command reconstruction so quoted rule arguments are preserved.

2. Policy refresh timing:
   - Re-apply host `DOCKER-USER` policy automatically after:
     - `agent update`
     - `agent rollback all <release_id>`

3. Source subnet scoping:
   - Introduce `AGENTIC_DOCKER_USER_SOURCE_NETWORKS` (default: `${AGENTIC_NETWORK}`) for subnet DROP enforcement source selection.
   - Resolve allow-target service IPs across both `${AGENTIC_NETWORK}` and `${AGENTIC_EGRESS_NETWORK}`.
   - Keep explicit allow rules for required internal services (`unbound`, `egress-proxy`, `ollama-gate`, `ollama`).
   - Add explicit allow for internal network east-west traffic (`src in source subnet -> dst in AGENTIC_NETWORK subnet`) before DROP.

4. Non-root local strict validation path:
   - Add guarded opt-in `AGENTIC_ALLOW_NON_ROOT_NET_ADMIN=1` for environments using a controlled `iptables` helper in `PATH`.
   - Default strict behavior remains root-required when this opt-in is not set.

## Consequences

- Positive:
  - Deterministic rollback path for host-net snapshots.
  - Host policy stays aligned with live container IPs after release operations.
  - Strict policy remains effective while avoiding false negatives caused by over-blocking internal service traffic.

- Tradeoffs:
  - Additional environment knobs increase operational surface (`AGENTIC_DOCKER_USER_SOURCE_NETWORKS`, `AGENTIC_ALLOW_NON_ROOT_NET_ADMIN`).
  - Non-root net-admin path must stay explicitly opt-in and documented to avoid accidental weakening.
