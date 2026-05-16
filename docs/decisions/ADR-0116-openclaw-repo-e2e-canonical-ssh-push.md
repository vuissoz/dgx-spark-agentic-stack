# ADR-0116: OpenClaw repo-e2e uses canonical Forgejo SSH push

## Status

Accepted

## Context

The narrow OpenClaw sandbox tool `repo.eight_queens.solve` was committing the
reference-repository fix correctly, but its publication path relied on a
temporary HTTP `GIT_ASKPASS` helper written under `/tmp`.

That was weaker than the stack's normal Git Forge contract and proved brittle in
the sandbox runtime when the helper stopped being executable.

## Decision

- Keep `repo.eight_queens.solve` as a narrow reviewed tool.
- Stop using a temporary HTTP askpass flow for its `git push`.
- Mount the canonical OpenClaw SSH material into `openclaw-sandbox`.
- Convert the checked-out repository `origin` URL to the canonical Forgejo SSH
  form and push through `GIT_SSH_COMMAND` with the managed key and
  `known_hosts`.

## Consequences

- The OpenClaw repo-e2e publication path now matches the stack's standard
  managed Git Forge SSH contract.
- The tool no longer depends on temporary executable auth helpers under `/tmp`.
- `openclaw-sandbox` now needs the same read-only OpenClaw SSH material already
  used by the main OpenClaw service.
