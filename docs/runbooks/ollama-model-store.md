# Runbook: Ollama Model Store (RW preload, RO smoke)

## Goal
- Preload one small chat model plus one embedding model.
- Keep model storage under a 12 GB budget.
- Re-mount models as read-only for smoke tests.

## Defaults
- Generate model: `${AGENTIC_DEFAULT_MODEL}` (fallback `llama3.1:8b`)
- Embedding model: `qwen3-embedding:0.6b`
- Budget: `12` GB

Global default model override (used by preload and onboarding defaults):

```bash
export AGENTIC_DEFAULT_MODEL=llama3.2:1b
```

## Commands
Preload then lock read-only:

```bash
./agent ollama-preload
```

Custom models/budget:

```bash
./agent ollama-preload --generate-model llama3.1:8b --embed-model qwen3-embedding:0.6b --budget-gb 12
```

Switch mount mode manually:

```bash
./agent ollama-models rw
./agent ollama-models ro
```

Rollback of the rootless models symlink (after `agent ollama-link` output `backup_id=<id>`):

```bash
./agent rollback ollama-link <backup_id|latest>
```

## Notes
- `ollama-preload` sets `OLLAMA_MODELS_MOUNT_MODE` in `${AGENTIC_ROOT}/deployments/runtime.env`.
- The mode persists for later `agent up core` / `agent update` runs.
- In `strict-prod`, run with privileges that can write `${AGENTIC_ROOT}`.
