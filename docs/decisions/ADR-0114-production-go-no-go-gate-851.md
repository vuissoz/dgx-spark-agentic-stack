# ADR-0114: Production Go/No-Go Gate For Issue 851

## Status

Accepted

## Context

Issue `dgx-spark-agentic-stack-851` defines the final production rollout gate for
four mandatory sub-items:

1. `dgx-spark-agentic-stack-ke0` - harden `ollama-gate` test mode defaults,
2. `dgx-spark-agentic-stack-2oj` - tighten uniform hardening baseline,
3. `dgx-spark-agentic-stack-dvo` - extend `agent doctor` deep checks uniformly,
4. `dgx-spark-agentic-stack-s7j` - ensure active release snapshot traceability after
   profile-based deploys.

By May 11, 2026, the codebase already contains the technical remediations for these
items, but the parent gate still requires an explicit rollout decision record and
strict-prod validation evidence captured on a target host.

No strict-prod validation artifact directory was present on the current host at:

- `/srv/agentic/deployments/validation/vm-strict-prod/`

Therefore the remaining gap is operational proof, not missing implementation.

## Decision

The production gate for `dgx-spark-agentic-stack-851` is now evaluated with the
following mandatory matrix.

### Mandatory gate matrix

| Item | Scope | Evidence in repo | Status |
| --- | --- | --- | --- |
| `dgx-spark-agentic-stack-ke0` | `ollama-gate` test mode must be disabled by default in production and only enabled explicitly for tests | `compose/compose.core.yml`, `scripts/lib/runtime.sh`, `scripts/agent.sh`, `README.fr.md`, `README.en.md` | PASS |
| `dgx-spark-agentic-stack-2oj` | hardening uniformity: non-root where feasible, explicit root exceptions, missing healthchecks fixed | `ADR-0031`, Compose service definitions, `tests/F6_hardening_matrix.sh` | PASS |
| `dgx-spark-agentic-stack-dvo` | `agent doctor` deep security checks applied uniformly across managed running services | `scripts/doctor.sh`, `tests/F6_hardening_matrix.sh` | PASS |
| `dgx-spark-agentic-stack-s7j` | active release snapshot present after supported profile-based deploy flows | `tests/F5_auto_release_manifest.sh`, auto-snapshot logic in `agent up` flow | PASS |
| strict-prod validation evidence | prod-like host or VM campaign proving `doctor`, `update`, `rollback`, and target selectors on strict-prod | `/srv/agentic/deployments/validation/vm-strict-prod/<timestamp>/` from `./agent vm test --name <vm>` | FAIL |

### Current rollout decision

As of May 11, 2026, the global decision for issue `dgx-spark-agentic-stack-851` is:

- `NO-GO`

Reason:

- the implementation-side controls pass,
- but no strict-prod validation artifact set is attached yet for the target host or a
  dedicated validation VM.

## Required evidence for a future GO decision

The gate may move from `NO-GO` to `GO` only after a strict-prod campaign succeeds and
stores evidence under:

- `/srv/agentic/deployments/validation/vm-strict-prod/<timestamp>/`

The canonical command is:

```bash
./agent vm test --name agentic-strict-prod
```

Expected minimum evidence set:

- `campaign.meta`
- `gpu-status.txt`
- `agent-doctor-initial.log`
- `agent-update.log`
- `agent-rollback.log`
- `agent-doctor-final.log`
- `agent-ps-final.log`
- per-selector test logs for the chosen validation campaign

If GPU passthrough is unavailable, `--allow-no-gpu` may be used only to produce an
explicit degraded proof set. That does not silently upgrade the gate to `GO`; the
blocked checks must remain visible in the captured artifacts.

## Consequences

- Production rollout stays blocked until strict-prod evidence exists.
- Tracker items that are already satisfied by code can be closed independently of the
  final rollout gate.
- Operators now have a single ADR that states both the current decision and the exact
  artifact path required to overturn it.
