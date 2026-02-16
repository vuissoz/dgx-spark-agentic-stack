# ADR-0014: Dual execution profiles (`rootless-dev` and `strict-prod`)

## Status
Accepted

## Context
The CDC requires host-level controls (notably `/srv/agentic` ownership/permissions and `DOCKER-USER` enforcement) that usually require root privileges. Development workflows also need a safe mode that does not require root access on the main host.

## Decision
- Introduce `AGENTIC_PROFILE` with two allowed values:
  - `strict-prod` (default): CDC-compliant target mode.
  - `rootless-dev`: local development mode without mandatory root host operations.
- Profile defaults are centralized in `scripts/lib/runtime.sh`:
  - `strict-prod`: `/srv/agentic`, compose project `agentic`, network checks enforced.
  - `rootless-dev`: `${HOME}/.local/share/agentic`, compose project `agentic-dev`, host-root checks skipped by default.
- `agent doctor` remains strict in `strict-prod`; in `rootless-dev`, root-only host checks degrade to warnings.
- Bootstrap and tests are profile-aware where semantics differ (filesystem and DOCKER-USER expectations).

## Consequences
- The repository now supports an explicit non-root development path.
- CDC compliance remains judged against `strict-prod`.
- Developers can iterate locally without weakening production guardrails.
