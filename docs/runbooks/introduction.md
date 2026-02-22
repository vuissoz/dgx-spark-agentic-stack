# Runbook: Stack Philosophy and Operating Model

This document explains the intent behind the DGX Spark Agentic Stack.
It is not a service-by-service reference; it is the "why" and "how to think about it" guide used to make consistent operational decisions.

If you only read one runbook before operating the platform, read this one first.

## What This Stack Optimizes For

The stack is designed for a practical balance:
- rapid local iteration for agentic workflows,
- strict operational traceability for updates and rollback,
- constrained network exposure,
- explicit, inspectable runtime state.

In plain terms:
- developers/operators should be able to move fast in `rootless-dev`,
- acceptance and production-like confidence should be established in `strict-prod`,
- each deployment should be explainable after the fact (what changed, when, and how to revert).

## Core Philosophy

### 1) Local-first exposure, remote access by tunnel

Host-published services are bound to loopback (`127.0.0.1`) rather than public interfaces.
Remote access is expected through Tailscale + SSH forwarding.

Reasoning:
- keep accidental exposure risk low by default,
- make network intent explicit and reversible,
- preserve a single secure ingress pattern for operators.

### 2) Operational determinism over convenience

The stack intentionally uses mutable upstream tags (`:latest`) for fast refresh cadence, but couples that with strict release snapshots and rollback artifacts.

Reasoning:
- you get fresh images quickly,
- you still preserve deterministic recovery (`agent rollback all <release_id>`),
- incidents can be reconstructed from saved digests/effective compose.

### 3) No hidden privilege escalations

Container hardening defaults exist to reduce blast radius:
- `cap_drop: ALL` by default,
- `no-new-privileges:true`,
- read-only rootfs where compatible,
- explicit writable mounts for state/logs/workspaces.

The stack also enforces explicit policy boundaries:
- no `docker.sock` mount in app containers,
- host-level egress control in strict mode,
- secrets outside git and with restrictive file permissions.

### 4) Profile-aware truth, not one-size-fits-all fiction

Two execution profiles are first-class:
- `strict-prod`: acceptance/compliance-oriented mode,
- `rootless-dev`: development mode with root-only host checks degraded.

Reasoning:
- pretending dev and prod constraints are identical leads to fragile workflows,
- profile-specific expectations make results interpretable,
- acceptance remains anchored to `strict-prod`.

### 5) Evidence-driven operations

Observability is treated as an operational requirement, not optional decoration:
- metrics (Prometheus exporters),
- logs (Loki + Promtail),
- proxy logs as egress ground truth,
- `agent doctor` as a structured compliance probe.

Reasoning:
- debugging should start from facts, not guesses,
- policy validation should be scriptable and repeatable,
- incidents should be diagnosable without ad-hoc privileged access.

## Architectural Mental Model

Think in planes, not individual containers:

1. Control/Policy Plane (`core`)
- `ollama`, `ollama-gate`, `unbound`, `egress-proxy`, `toolbox`
- defines inference gateway behavior and outbound policy path.

2. Execution Plane (`agents`)
- tmux-backed agent runtimes with isolated state/log/workspaces.

3. Interaction Plane (`ui`)
- OpenWebUI, OpenHands, ComfyUI (+ loopback bridge).

4. Observability Plane (`obs`)
- Prometheus/Grafana/Loki/Promtail + host/container/GPU exporters.

5. Data/Retrieval Plane (`rag`)
- Qdrant persistence and retrieval scripts.

6. Gated Extensions (`optional`)
- explicit opt-in modules with request/secrets prerequisites and policy checks.

This segmentation is intentional:
- failure in one plane should be diagnosable without tearing down all others,
- upgrades can be reasoned about by surface area,
- runtime ownership and persistence boundaries stay explicit.

## Persistence Philosophy

Persistent state lives under a runtime root (`AGENTIC_ROOT`):
- `/srv/agentic` in `strict-prod`,
- `${HOME}/.local/share/agentic` in `rootless-dev` by default.

The contract is:
- no hidden state inside ephemeral container rootfs,
- no implicit writes outside declared mounts for persistent concerns,
- path overrides happen via environment variables and are visible in `agent profile`.

For observability host telemetry mounts, path sources are also parameterized (for portability across host layouts).

## Network and Egress Philosophy

The egress model is layered:
- app/service outbound requests go through proxy variables,
- DNS + proxy are controlled core services,
- strict mode may enforce host firewall controls (`DOCKER-USER`) to reduce bypass paths.

Pragmatic note:
- `rootless-dev` favors developer operability, so some host-root checks are warnings/skips,
- `strict-prod` is where full host-policy expectations are enforced.

## Security Philosophy (Pragmatic, Not Performative)

The stack is not trying to be an academic "perfectly locked down" environment.
It aims for strong default guardrails that are practical to operate:
- narrow exposure surface,
- explicit writable mounts,
- minimized capabilities,
- explicit secrets handling,
- no silent privilege shortcuts.

Security controls are only useful if operators can keep them enabled during normal work.
This runbook family favors controls that survive real operational pressure.

## Change Management Philosophy

Expected workflow:
1. select profile and confirm with `agent profile`,
2. apply/start stacks in bounded steps (`core` first),
3. run `agent doctor` and targeted tests,
4. capture updates via `agent update`,
5. rollback deterministically if needed.

What matters:
- you can explain the current state,
- you can reproduce it,
- you can revert it quickly.

## Failure Philosophy

A "good" failure is:
- explicit,
- localized,
- actionable,
- reversible.

Examples:
- healthcheck fails with concrete root cause,
- doctor output points to precise control drift,
- release rollback restores previously-known-good digests/config.

The stack intentionally favors early, visible failure over silent drift.

## How To Read the Rest of Runbooks

Suggested order:
1. this introduction (`introduction.md`),
2. `onboarding-ultra-simple.fr.md` / `.en.md` / `.de.md` / `.it.md` (non-technical quickstart),
3. `profiles.md` (execution semantics),
4. `configuration-expliquee-debutants.md` (beginner-friendly FR configuration reference),
5. `configuration-explained-beginners.en.md` (beginner-friendly EN configuration reference),
6. `first-time-setup.md` (day-0 bootstrap),
7. `strict-prod-vm.md` (dedicated VM path for prod-like validation),
8. `features-and-agents.md` (component capabilities),
9. `services-expliques-debutants.md` (beginner-friendly service-by-service guide),
10. `services-explained-beginners.en.md` (English beginner-friendly service-by-service guide),
11. `codex-debutant.md` (beginner step-by-step usage of `agentic-codex`),
12. specialized runbooks (`optional-modules.md`, `observability-triage.md`, etc.).

When troubleshooting:
- always capture active profile and effective runtime values first (`./agent profile`),
- then use `./agent doctor`,
- then isolate by stack plane (`core`, `agents`, `ui`, `obs`, `rag`, `optional`).

## Operational North Star

The stack is healthy when:
- services are loopback-scoped and policy-constrained,
- state is explicit and recoverable,
- updates are traceable,
- rollback is deterministic,
- diagnostics are factual and fast,
- developers can iterate without bypassing the security model.
