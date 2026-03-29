# ADR-0093: Explicit Ollama egress hardening after dual-network publish

## Status
Accepted (2026-03-29)

## Context

Step C publishes `ollama` on host loopback by attaching the container to both:

- `${AGENTIC_NETWORK}` for internal service traffic;
- `${AGENTIC_EGRESS_NETWORK}` for the host-facing loopback publish path.

That dual-network layout creates a follow-up hardening requirement captured by issue `dgx-spark-agentic-stack-lfj`: `ollama` now has an egress-capable interface and must be constrained explicitly at the host `DOCKER-USER` layer without breaking the services that legitimately need outbound access (`unbound` recursion and `egress-proxy` upstream web access).

## Decision

1. Keep the subnet-scoped `DOCKER-USER` policy for the general stack baseline.
2. Add service-specific source rules on `${AGENTIC_EGRESS_NETWORK}`:
   - `unbound` is allowed to reach arbitrary `tcp/53` and `udp/53` destinations;
   - `egress-proxy` is allowed to reach arbitrary `tcp/80` and `tcp/443` destinations;
   - `ollama` is allowed only to:
     - the internal `${AGENTIC_NETWORK}` subnet,
     - `unbound` on `tcp/53` and `udp/53`,
     - `egress-proxy` on `tcp/3128`,
     - then it is explicitly logged and dropped for everything else.
3. Extend shared `DOCKER-USER` assertions so `agent doctor` and the strict-prod B4 acceptance test verify those explicit rules, not just the generic subnet DROP.

## Consequences

- `ollama` keeps its loopback publish path but cannot bypass the stack egress controls directly.
- `unbound` and `egress-proxy` no longer depend on accidental gaps in the subnet-wide DROP policy; their required outbound flows are explicit and auditable.
- `rootless-dev` continues to skip host-root-only `DOCKER-USER` enforcement checks by default; the new guarantees are enforced and verified in environments where host netfilter control is available.
