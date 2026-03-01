# Runbook: Implementation Strategy and Refactoring Priorities

This note reviews how `PLAN.md` is implemented in the current repository and where refactoring will provide the highest operational value.

## Current Strategy (What Works Well)

The implementation follows a pragmatic pattern:
- Compose files are split by stack plane (`core`, `agents`, `ui`, `obs`, `rag`, `optional`).
- The `agent` command is the operator entry point for deploy, diagnostics, update, rollback, and tests.
- Hardening and compliance are enforced by both runtime checks (`agent doctor`) and static checks (`tests/F6_hardening_matrix.sh`).
- Update/rollback traceability is implemented with release snapshots in `${AGENTIC_ROOT}/deployments/releases/<timestamp>/`.

This is aligned with the CDC goals: local-only exposure, controlled egress, explicit persistence, and reproducible operations.

## Does It Need Refactoring?

Yes, targeted refactoring is recommended.

Why:
- `scripts/agent.sh` has grown to a monolithic command router and orchestration layer (around 2500 lines), which increases coupling and change risk.
- Runtime configuration keys are duplicated across `scripts/lib/runtime.sh`, `load_runtime_env`, `ensure_runtime_env`, and `cmd_profile`, which can drift over time.
- Compose service definitions repeat the same hardening and proxy blocks in many places, increasing maintenance overhead.
- Rollback is close to deterministic but not fully hermetic today because `deployments/releases/rollback.sh` reuses live compose files listed in `compose.files` instead of replaying only snapshot artifacts.

## Priority Refactoring Roadmap

### Priority 0: Make Rollback Fully Hermetic

Problem:
- `rollback.sh` currently depends on compose files from the working tree.

Refactor:
- Roll back from snapshot-only artifacts (`compose.effective.yml` + pinned images manifest), not from mutable repo compose files.
- Keep current behavior as fallback only for legacy releases.

Expected gain:
- Deterministic rollback independent of later repository edits.
- Stronger CDC compliance for "exact restore".

### Priority 1: Split `agent.sh` into Command Modules

Problem:
- Command parsing, business logic, image build logic, runtime env handling, and test orchestration are tightly mixed.

Refactor:
- Keep `scripts/agent.sh` as a thin CLI dispatcher.
- Move command families into dedicated files:
  - `scripts/cmd/stack.sh`
  - `scripts/cmd/runtime.sh`
  - `scripts/cmd/release.sh`
  - `scripts/cmd/ops.sh`
  - `scripts/cmd/test.sh`

Expected gain:
- Lower cognitive load.
- Safer reviews and easier test coverage per command family.

### Priority 2: Create a Single Runtime Env Schema

Problem:
- Allowed keys/defaults are repeated in multiple places.

Refactor:
- Define one authoritative env schema file (key, default, persistence policy, sensitivity).
- Generate:
  - export/default logic,
  - runtime persistence logic,
  - profile output (`agent profile`),
  - validation and redaction behavior.

Expected gain:
- Reduced drift and faster onboarding for new variables.

### Priority 3: Reduce Compose Duplication with Anchors/Extensions

Problem:
- Repeated hardening and proxy snippets across many services.

Refactor:
- Introduce shared extension blocks (`x-security-defaults`, `x-proxy-env`, `x-health-defaults`) and reference them in service definitions.
- Keep explicit exceptions documented inline for root/capability cases.

Expected gain:
- Fewer copy/paste errors.
- Easier hardening updates across all planes.

### Priority 4: Unify Compliance Rules Between Doctor and Static Matrix

Problem:
- Runtime checks in `doctor.sh` and static checks in `tests/F6_hardening_matrix.sh` can diverge.

Refactor:
- Externalize policy expectations into a machine-readable policy file.
- Use the same policy source in doctor and static tests.

Expected gain:
- One source of truth for compliance.
- Fewer false positives and fewer missed regressions.

## Recommended Delivery Strategy

Use incremental, low-risk changes:
1. Land Priority 0 first (highest operational risk reduction).
2. Split `agent.sh` by command family without changing user-facing CLI.
3. Introduce shared env schema and migrate commands progressively.
4. Refactor compose with no behavior change, guarded by existing tests.
5. Consolidate policy checks last, after behavior is stable.

Avoid a big-bang rewrite.

## Acceptance Criteria for the Refactoring Program

- `./agent doctor` remains green for nominal deployments.
- `./agent update` and `./agent rollback all <release_id>` remain backward compatible.
- Existing tests in `tests/` stay green or are replaced with equivalent/higher coverage.
- Rollback no longer depends on mutable compose files from the current working tree.
