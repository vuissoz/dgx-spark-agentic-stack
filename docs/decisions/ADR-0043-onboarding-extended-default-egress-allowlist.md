# ADR-0043: Onboarding default egress allowlist uses extended curated domain set

## Status
Accepted

## Context
Onboarding previously generated `${AGENTIC_ROOT}/proxy/allowlist.txt` from a very small inline CSV default (`example.com,api.openai.com,openrouter.ai`).
This made first-day usage brittle for common developer workflows (source hosting, package registries, model downloads, and literature lookup), and the onboarding default could drift from `examples/core/allowlist.txt`.

## Decision
- Expand `examples/core/allowlist.txt` with an explicit curated domain list (no wildcard default entries), grouped by usage category.
- Keep `openrouter.ai` and `example.com` for compatibility with existing workflows/tests.
- Make `deployments/bootstrap/onboarding_env.sh` load onboarding default allowlist values from `examples/core/allowlist.txt` instead of a hardcoded inline CSV fallback.
- Keep `--allowlist-domains` override behavior unchanged for operators who need stricter or custom policy.

## Consequences
- `agent onboard` now writes a richer default `${AGENTIC_ROOT}/proxy/allowlist.txt` on fresh setups.
- Core runtime bootstrap (`init_runtime.sh`) and onboarding now share one canonical default list source, reducing config drift.
- Operators should still trim the allowlist to least privilege for production-hardening after bootstrap.
