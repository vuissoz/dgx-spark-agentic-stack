# ADR-0019: Strict-prod VM validation campaign via `agent vm test`

## Status
Accepted

## Context
`PLAN.md` step V1 requires a reproducible prod-like validation campaign inside a dedicated VM, including:
- strict-prod bootstrap/startup,
- `doctor`, `update`, deterministic `rollback`,
- test campaign execution,
- durable proof artifacts under `/srv/agentic/deployments/validation/vm-strict-prod/<timestamp>/`.

Before this ADR, the repo only exposed VM provisioning (`agent vm create`) and required manual command chaining for validation.

## Decision
- Add a dedicated VM validation script: `deployments/vm/test_strict_prod_vm.sh`.
- Expose it through operator CLI as:
  - `agent vm test ...`
- Keep strict-prod as the only profile used by this campaign.
- Capture evidence artifacts in the VM under:
  - `/srv/agentic/deployments/validation/vm-strict-prod/<timestamp>/`
- Include logs/proofs for:
  - bootstrap,
  - stack startup,
  - doctor (initial/final),
  - update + release id,
  - rollback target id,
  - per-selector test logs and summary,
  - final `agent ps`,
  - campaign metadata and GPU status.
- Add explicit GPU policy:
  - default `--require-gpu` behavior for strict validation,
  - `--allow-no-gpu` degraded mode keeps security controls intact while explicitly marking blocked GPU-coupled checks in artifacts.

## Consequences
- Operators can trigger the full VM validation flow from one command.
- V1 evidence is generated in a deterministic location with machine-readable metadata.
- CPU-only VMs remain usable for partial/progressive validation without silently weakening controls; skipped checks are documented explicitly.
