# ADR-0030 - Step BLW resource limits customization

Date: 2026-02-21

## Context

`PLAN.md` backlog item `dgx-spark-agentic-stack-blw` requires runtime/onboarding customization of CPU and RAM limits for the containerized stack.

The stack already had security hardening and release traceability, but no uniform resource cap controls.
This made constrained hosts harder to onboard and increased OOM/restart risk when optional modules were enabled.

## Decision

1. Add explicit CPU/RAM limits on every service in all Compose stacks (`core`, `agents`, `ui`, `obs`, `rag`, `optional`).
2. Use a three-level override model:
   - service-level (`AGENTIC_LIMIT_<SERVICE>_{CPUS|MEM}`),
   - stack-level (`AGENTIC_LIMIT_<STACK>_{CPUS|MEM}`),
   - global fallback (`AGENTIC_LIMIT_DEFAULT_{CPUS|MEM}`).
3. Define profile-aware defaults in `scripts/lib/runtime.sh`:
   - stricter defaults for `rootless-dev`,
   - slightly higher defaults for `strict-prod`.
4. Extend onboarding wizard (`deployments/bootstrap/onboarding_env.sh`) to:
   - collect default + stack-level limits,
   - validate CPU format (`>0`) and memory format (`512m`, `1g`, ...),
   - generate a sourceable env file with limit exports.
5. Persist limit defaults in `${AGENTIC_ROOT}/deployments/runtime.env` via `agent` runtime management.

## Consequences

- Operators can tune resource usage without editing Compose files.
- Per-service tuning is available when needed, while onboarding stays focused on stack-level defaults.
- Effective limits remain traceable via runtime env + compose effective config captured in releases.
