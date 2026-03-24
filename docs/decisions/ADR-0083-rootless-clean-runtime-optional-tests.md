# ADR-0083: Rootless clean-runtime isolation for Ollama link state and optional K tests

## Status
Accepted

## Context
- `rootless-dev` defaulted `AGENTIC_OLLAMA_MODELS_LINK` to a repo-global path under `.runtime/ollama-models`.
- On machines that already reused this repository for another rootless stack, `agent first-up` in a clean runtime root could fail before any service started because the shared symlink already pointed elsewhere.
- Optional module regression tests `K2` to `K5` created files under `${AGENTIC_ROOT:-/srv/agentic}` without loading runtime defaults, so `AGENTIC_PROFILE=rootless-dev` alone was not enough to run them safely as a non-root user.

## Decision
1. Scope the default rootless Ollama symlink path to the selected runtime root:
   - `AGENTIC_OLLAMA_MODELS_LINK=${AGENTIC_ROOT}/deployments/ollama-link/models`
2. Scope the default rootless Ollama target directory to the runtime root as well:
   - fallback target `${AGENTIC_ROOT}/ollama/models`
3. Make optional K-module tests load `scripts/lib/runtime.sh` so rootless defaults are derived the same way as the `agent` wrapper.
4. Add regression coverage in `F9_first_up_command.sh` for the rootless default link path.

## Consequences
- A clean `rootless-dev` runtime no longer collides with stale repo-global Ollama symlink state by default.
- `K2`/`K3`/`K4`/`K5` can run with `AGENTIC_PROFILE=rootless-dev` without manually exporting `AGENTIC_ROOT`.
- Operators can still override both the symlink path and real target via `AGENTIC_OLLAMA_MODELS_LINK`, `AGENTIC_OLLAMA_MODELS_TARGET_DIR`, or onboarding-provided `OLLAMA_MODELS_DIR`.
