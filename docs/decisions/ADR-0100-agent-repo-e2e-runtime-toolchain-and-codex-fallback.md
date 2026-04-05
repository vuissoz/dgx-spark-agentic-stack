# ADR-0100: Repo-e2e task toolchain in all agent containers

## Status

Accepted

## Context

The repository-driven E2E scenario requires each agent container to execute the
same baseline repository workflow from inside its own container:

- `git pull`
- edit files
- `python3 -m pytest -q`
- `git commit`
- `git push`

Observed failures showed two stack-level gaps:

1. several agent images did not ship `pytest`, so the repository contract could
   not be satisfied in-container;
2. `codex` command execution failed under managed containers because the host
   container policy blocked the namespace path used by `bubblewrap`.

The stack already provides external containment for these runtimes:

- loopback-only host exposure,
- private Docker network,
- explicit writable mounts only,
- no `docker.sock`,
- dropped capabilities and `no-new-privileges` by default.

## Decision

- Ship the repo-task Python toolchain (`git`, `python3`, `pytest`) in every
  agent image that participates in `repo-e2e`.
- Replace the upstream Goose image reference with a stack-managed derived image
  so the same task toolchain is present there as well.
- Make the managed `codex` wrapper detect when namespace sandboxing is not
  available and fall back to `--dangerously-bypass-approvals-and-sandbox`
  inside the already-constrained container runtime.

## Consequences

- `repo-e2e` no longer depends on ad hoc package installation inside running
  containers.
- The runtime contract becomes testable at container level for all agents.
- `codex` no longer hard-fails on `bwrap` in environments where unprivileged
  user namespaces are blocked by container policy, at the cost of relying on
  the stack’s outer container isolation rather than Codex’s inner sandbox.
