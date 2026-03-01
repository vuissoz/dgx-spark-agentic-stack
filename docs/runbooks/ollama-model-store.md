# Runbook: Ollama Model Store (state-preserving preload)

## Goal
- Preload one small chat model plus one embedding model.
- Keep model storage under a 12 GB budget.
- Preserve the initial mount mode (`rw` or `ro`) after preload.

## Defaults
- Generate model: `${AGENTIC_DEFAULT_MODEL}` (fallback `llama3.1:8b`)
- Embedding model: `qwen3-embedding:0.6b`
- Budget: `12` GB

Global default model override (used by preload and onboarding defaults):

```bash
export AGENTIC_DEFAULT_MODEL=llama3.2:1b
```

## Commands
Preload with automatic mode preservation:

```bash
./agent ollama-preload
```

Custom models/budget:

```bash
./agent ollama-preload --generate-model llama3.1:8b --embed-model qwen3-embedding:0.6b --budget-gb 12
```

Switch mount mode manually:

```bash
./agent ollama-models status
./agent ollama-models rw
./agent ollama-models ro
```

Rollback of the rootless models symlink (after `agent ollama-link` output `backup_id=<id>`):

```bash
./agent rollback ollama-link <backup_id|latest>
```

## Notes
- `ollama-preload` now preserves the initial Ollama model mount mode:
  - if already `rw`, no mount-mode recreate is triggered and final mode stays `rw`;
  - if initially `ro`, preload switches to `rw` temporarily, then restores `ro` by default.
- `--no-lock-ro` keeps `rw` after preload when a temporary switch occurred.
- final `OLLAMA_MODELS_MOUNT_MODE` is written to `${AGENTIC_ROOT}/deployments/runtime.env`.
- In `strict-prod`, run with privileges that can write `${AGENTIC_ROOT}`.
