# Runbook: Ollama Model Store (state-preserving preload)

## Goal
- Preload one small chat model plus one embedding model.
- Keep model storage under a 32 GB budget.
- Preserve the initial mount mode (`rw` or `ro`) after preload.

## Defaults
- Generate model: `${AGENTIC_DEFAULT_MODEL}` (fallback `nemotron-cascade-2:30b`)
- Embedding model: `qwen3-embedding:0.6b`
- Budget: `32` GB

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
./agent ollama-preload --generate-model nemotron-cascade-2:30b --embed-model qwen3-embedding:0.6b --budget-gb 32
```

Switch mount mode manually:

```bash
./agent ollama-models status
./agent ollama unload qwen3-coder:30b
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
- `agent ollama unload <model>` unloads a currently loaded model from Ollama memory, returns success with `result=already-unloaded` when the model is not loaded, and logs the action to `${AGENTIC_ROOT}/deployments/changes.log`.
- initial unload scope is Ollama only; no TRT-LLM unload contract is introduced yet.
- In `strict-prod`, run with privileges that can write `${AGENTIC_ROOT}`.
