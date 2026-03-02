# Plan - dgx-spark-agentic-stack-5f1

## Objective
Ensure `agentic-codex` in `rootless-dev` bootstraps a known model catalog for `AGENTIC_DEFAULT_MODEL` (including `qwen3.5:35b`) so Codex does not fall back to unknown-model metadata, and add an automated verification path.

## Scope
- Bootstrap/migrate Codex runtime config in `agent-cli-base` entrypoint.
- Add deterministic test validating config + runtime execution on local model.
- Update docs (ADR + setup runbook).

## Steps
1. Add codex catalog bootstrap function in entrypoint:
- create `/state/bootstrap/codex-model-catalog.json` if missing,
- populate it with `AGENTIC_DEFAULT_MODEL` metadata compatible with Codex model schema,
- wire `model_catalog_json` into `~/.codex/config.toml`.

2. Add idempotent migration logic for existing `~/.codex/config.toml`:
- keep existing user options,
- enforce/repair `model`, `model_provider`, provider block, and `model_catalog_json`.

3. Add test `tests/L6_codex_model_catalog.sh`:
- verify config has `model_catalog_json`,
- verify catalog JSON contains `AGENTIC_DEFAULT_MODEL`,
- execute `codex exec` from `agentic-codex` and assert no fallback metadata warning.

4. Update docs:
- ADR documenting why custom catalog is needed for local non-OpenAI models.
- runbook update for new validation command.

5. Validation:
- run test(s) for onboarding/config and new L6 test,
- commit + `bd sync` + push.
