# ADR-0079: OpenClaw module blueprint manifest

## Status

Accepted

## Context

Issue `dgx-spark-agentic-stack-zj4` asks for a module contract similar in spirit to a lifecycle blueprint:

- explicit preconditions,
- auditable artefacts,
- status/compatibility rules,
- a documented relation to stack-level releases.

The repository already snapshots global releases under `${AGENTIC_ROOT}/deployments/releases`, but OpenClaw had no single versioned manifest that described its own module contract.

## Decision

Add a versioned manifest template:

- repo template: `examples/optional/openclaw.module-manifest.v1.json`
- runtime location: `${AGENTIC_ROOT}/openclaw/config/module/openclaw.module-manifest.v1.json`

The manifest declares:

- required files and state roots,
- loopback host ports and internal endpoints,
- auth modes,
- compatibility profiles,
- CLI version probe policy,
- lifecycle stages:
  - `resolve`
  - `verify`
  - `plan`
  - `apply`
  - `status`
- relation to stack-level release snapshots.

Validation path:

- `deployments/optional/openclaw_module_manifest.py validate` checks schema/shape,
- `deployments/core/init_runtime.sh` bootstraps the runtime copy,
- `agent doctor` validates the manifest and checks that the running services/env match its contract.

## Consequences

- OpenClaw now has a local module contract that the operator and `agent doctor` can inspect directly.
- The manifest does not duplicate release digests; it points to the global release mechanism instead.
- No secrets are stored in the manifest.
