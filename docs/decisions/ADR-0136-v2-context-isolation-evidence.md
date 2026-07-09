# ADR-0136: Context-isolation evidence producer for v2

Date: 2026-07-09

Status: accepted

## Context

The v2 evaluator needs machine evidence for each P0 walking-skeleton journey. Bootstrap-doctor evidence exists, but context isolation was still only a planned requirement.

The deployed v2 control plane and OpenShell runtime isolation are not implemented yet, so this slice must not claim runtime isolation. It can still make progress by creating a repo-owned local policy oracle that later runtime evidence must satisfy.

## Decision

Add `scripts/produce_v2_context_isolation_evidence.py`.

The producer creates disposable personal and project context roots, then records:

- positive same-context reads for personal and project files;
- a negative cross-context access attempt from the personal context into a project-private file;
- a `pass` journey only when same-context reads succeed and cross-context access is refused.

The evidence is explicitly marked as `local_simulated_policy`. It proves the policy oracle and artifact shape, not deployed runtime enforcement.

A test-only `--unsafe-allow-cross-context` mode disables the path guard to prove the producer fails closed when leakage is possible.

## Consequences

The evaluator can now consume pass-shaped context-isolation evidence while still quarantining the full candidate until bootstrap, model-backend-failure, snapshot-restore-rollback, and remaining P0 gates are fully evidenced.

Future v2 runtime work must replace or supplement this simulated evidence with deployed context creation, mount policy, and negative leakage checks.
