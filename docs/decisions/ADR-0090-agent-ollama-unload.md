# ADR-0090 — `agent ollama unload` for explicit local model offload

## Context

OpenWebUI already exposes an explicit operator action to unload a locally loaded model from Ollama memory in `rootless-dev`, but the stack wrapper had no equivalent CLI path. This left an operational gap for freeing GPU/RAM without using the web UI.

The command must stay aligned with the repository posture:

- loopback-only access,
- no `docker.sock` mounted into workloads,
- operator actions recorded in stack-managed state,
- no security relaxation just to expose a convenience feature.

## Decision

Add `agent ollama unload <model>` as the stack-managed operator command for explicit local model offload.

Scope for the initial implementation:

- backend target is `Ollama` only,
- the command checks the running `ollama` Compose service from the host wrapper,
- it uses the Ollama CLI inside the backend container to inspect loaded models and to stop a loaded model,
- each invocation appends an audit-style line to `${AGENTIC_ROOT}/deployments/changes.log`.

Behavior contract:

- if the backend is not running, fail closed with an actionable error,
- if the model is not currently loaded, return success with `result=already-unloaded`,
- if the model is loaded, unload it and return success with `result=unloaded`.

## Consequences

- The command is idempotent for the common "already gone" operator case.
- There is no session-level reference counting in the stack wrapper: unloading is an operator action applied at the Ollama backend scope.
- Future backend-specific expansion remains possible (`trtllm`, unified `agent model ...` surface), but is deferred until a real multi-backend unload contract is needed.
