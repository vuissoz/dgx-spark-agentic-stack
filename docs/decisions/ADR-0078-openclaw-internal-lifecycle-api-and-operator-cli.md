# ADR-0078: OpenClaw internal sandbox lifecycle API separated from operator CLI

## Status

Accepted

## Context

Issue `dgx-spark-agentic-stack-0n8` requires a stricter separation inside OpenClaw:

- the OpenClaw main service must manage sandbox lifecycle through a machine-to-machine contract,
- the operator must keep a separate local CLI surface (`agent openclaw ...`),
- both surfaces must observe the same runtime state without routing lifecycle control through the host wrapper `./agent`.

The existing stack already had:

- an execution registry in `openclaw-sandbox`,
- an operator registry for summaries,
- an operator shell entrypoint via `agent openclaw`.

But lifecycle creation/reuse was still implicitly coupled to tool execution on `openclaw-sandbox`, and the host CLI had no first-class status/policy/model/sandbox verbs.

## Decision

Introduce two explicit planes over the same runtime:

1. Internal lifecycle API on `openclaw-sandbox`
   - `POST /v1/internal/sandboxes`
   - `POST /v1/internal/sandboxes/lease`
   - `POST /v1/internal/sandboxes/attach-or-reuse`
   - `GET /v1/internal/sandboxes`
   - `GET /v1/internal/sandboxes/<sandbox_id>`
   - `DELETE /v1/internal/sandboxes/<sandbox_id>`
2. Operator CLI on the host
   - `agent openclaw status [--json]`
   - `agent openclaw policy list|add`
   - `agent openclaw model set <id>`
   - `agent openclaw sandbox ls|attach|destroy`
   - existing `agent openclaw approvals ...`

Runtime behavior:

- `openclaw` now resolves a sandbox lease through `OPENCLAW_SANDBOX_LIFECYCLE_URL` before forwarding tool execution.
- `openclaw-sandbox` still executes the tool, but lifecycle ownership is now exposed through a dedicated internal API.
- operator commands read or mutate the same host-backed runtime artefacts:
  - operator registry,
  - operator runtime file,
  - allowlist files,
  - sandbox registry via the internal lifecycle API for destructive actions.

## Consequences

- lifecycle control is explicit and machine-facing instead of being an incidental side effect of the public tool execution path,
- operator workflows gain auditable local commands without exposing new public ports,
- `agent doctor` can now verify coherence between:
  - the operator registry,
  - the operator runtime file,
  - the internal lifecycle API.
