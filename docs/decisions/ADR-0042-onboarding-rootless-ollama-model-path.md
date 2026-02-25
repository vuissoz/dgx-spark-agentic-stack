# ADR-0042: Onboarding rootless default Ollama model path aligned with local Open WebUI workspace

## Status
Accepted

## Context
Rootless onboarding previously defaulted `OLLAMA_MODELS_DIR` to repository-local `.runtime/ollama-models`.
In user environments where models are already managed under `~/wkdir/open-webui/ollama_data`, this created drift:
- onboarding suggested one path,
- rootless link bootstrap could resolve to another target if not explicitly overridden.

## Decision
- Change rootless onboarding default `OLLAMA_MODELS_DIR` to:
  - `${HOME}/wkdir/open-webui/ollama_data/models`
- During onboarding in `rootless-dev`, create (when writable):
  - `${...}/models`
  - `${...}/tmp` (sibling of `models`)
- Update rootless `setup-ollama-models-link.sh` target resolution:
  - if `AGENTIC_OLLAMA_MODELS_TARGET_DIR` is not set,
  - and `OLLAMA_MODELS_DIR` is set to a path different from the link path,
  - use `OLLAMA_MODELS_DIR` as effective target directory.
  - otherwise keep fallback `${REPO}/.runtime/ollama-models-data`.

## Consequences
- `agent onboard` now proposes the expected local Open WebUI Ollama storage layout by default.
- Rootless link bootstrap follows onboarding-provided model path instead of silently reverting to repository-local target defaults.
- Existing operators can still override via `--ollama-models-dir` or explicit `AGENTIC_OLLAMA_MODELS_TARGET_DIR`.
