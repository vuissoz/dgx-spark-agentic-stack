# ADR-0018: Dedicated strict-prod VM creation via `agent vm create`

## Status
Accepted

## Context
Step V1 in `PLAN.md` requires a dedicated Linux VM path to run `strict-prod` validation without changing the main host.  
The VM must be reproducible, memory must be configurable, and GPU presence must be checkable.

## Decision
- Add a dedicated VM creation script: `deployments/vm/create_strict_prod_vm.sh`.
- Expose it through operator CLI as:
  - `agent vm create ...`
- Use Multipass as the automated provider for this first implementation.
- Make RAM/CPU/disk explicit runtime flags (`--memory`, `--cpus`, `--disk`) instead of hardcoded values.
- Enforce a strict optional GPU gate:
  - `--require-gpu` fails if `nvidia-smi` is not usable in the VM.
- Keep destructive behavior opt-in:
  - if VM already exists, creation fails unless `--reuse-existing` is passed.

## Consequences
- Operators can create a prod-like `strict-prod` VM from the same repo and CLI surface.
- VM creation is deterministic enough for iterative validation while remaining safe-by-default.
- GPU passthrough still depends on host hypervisor setup; the script validates visibility but does not bypass platform limits.
