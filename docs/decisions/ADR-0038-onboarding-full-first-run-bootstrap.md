# ADR-0038: Extend `agent onboard` to cover full first-run bootstrap

## Status
Accepted

## Context

The original onboarding wizard (`deployments/bootstrap/onboarding_env.sh`) only generated runtime environment exports.
This left first-time operators with hidden sequencing around UI admin bootstrap (`openwebui.env`) and often resulted in default credentials (`admin@local` / `change-me`) being kept unintentionally.

`PLAN.md` item `0.5` requires a more complete first-start assistant that can cover runtime, UI admin bootstrap, allowlist, and selected secrets with explicit recap and actionable failures.

## Decision

Extend `agent onboard` to a sectioned first-run wizard that now:

1. Keeps existing runtime/profile/cpu/memory prompts and generated `env.generated.sh` output.
2. Adds UI bootstrap section to create/update:
   - `${AGENTIC_ROOT}/openwebui/config/openwebui.env`
   - `${AGENTIC_ROOT}/openhands/config/openhands.env`
3. Adds network bootstrap section to write initial:
   - `${AGENTIC_ROOT}/proxy/allowlist.txt`
4. Adds secret bootstrap section to write selected files under:
   - `${AGENTIC_ROOT}/secrets/runtime/*` with mode `0600`
5. Adds a final summary listing generated files, deferred actions, modules prepared, next commands, and blocking issues.
6. Adds `--require-complete` to fail with non-zero status when onboarding remains incomplete (for strict automation/CI).

## Consequences

- First-time setup becomes explicit and less error-prone, especially for OpenWebUI login bootstrap.
- Non-interactive automation remains available while gaining stricter completeness enforcement when requested.
- In non-writable contexts (typical `strict-prod` without sudo), onboarding can still generate runtime env output and report deferred file bootstrap work clearly.
