# ADR-0036: Profile-scoped cleanup with symlink-safe purge and stack image removal

## Status
Accepted

## Context
`agent cleanup` must reset runtime state to a brand-new baseline for both execution profiles:
- `strict-prod` (`/srv/agentic`)
- `rootless-dev` (`${HOME}/.local/share/agentic`)

The operator requested explicit profile-prefixed invocation (`agent strict-prod cleanup` / `agent rootless-dev cleanup`), plus two safety/operability guarantees:
- cleanup must not follow symlinks while deleting runtime content;
- cleanup must also remove local Docker images associated with the stack.

## Decision
- Add profile-prefix dispatch at `./agent` entrypoint:
  - first argument `strict-prod` or `rootless-dev` sets `AGENTIC_PROFILE` and shifts arguments.
- Keep `agent cleanup` as canonical command, with profile-prefixed aliases supported by the wrapper.
- Enforce symlink-safe runtime deletion:
  - reject cleanup when `AGENTIC_ROOT` itself is a symlink;
  - purge only first-level entries under `AGENTIC_ROOT` with `find -P ... -exec rm -rf --one-file-system -- {} +`;
  - this removes symlink entries but does not traverse symlink targets.
- Remove stack-related local images during cleanup:
  - collect image refs from compose config (`config --images`), compose project containers, and known local stack images;
  - remove images best-effort via `docker image rm -f`, while tolerating in-use/protected failures.

## Consequences
- Operators can run explicit-profile cleanup commands without exporting environment variables first.
- Cleanup is safer against accidental deletion through symlink traversal.
- Cleanup more reliably returns host state to a fresh baseline by removing stack images, at the cost of later image re-pulls/rebuilds on next deploy.
