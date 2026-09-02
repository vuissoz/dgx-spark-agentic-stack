# ADR-0144: Discover Codex metadata through the managed model gate

## Status

Accepted.

## Context

Codex consults its local metadata catalog before invoking a model. A catalog that
contains only the platform default produces fallback-metadata warnings for valid
non-default local models, despite those models being reachable through
`ollama-gate`.

## Decision

The managed Codex entrypoint builds a catalog from three sources, in order:

1. the configured active model;
2. `AGENTIC_CODEX_CATALOG_MODELS`, a reviewed comma-separated seed (default
   `qwen3.5:35b`);
3. the best-effort `ollama-gate /v1/models` response at startup.

The agent never queries Ollama or another backend directly. Gate discovery is
bounded to three seconds and failure leaves the deterministic seeded catalog
available, so startup does not depend on core convergence. All discovered entries
receive the same managed local-provider policy and compaction metadata; the active
model retains priority.

## Consequences

- Valid local non-default models have metadata instead of a fallback warning.
- Operators can seed a model that is not yet visible during startup without
  changing the image.
- `tests/F30_codex_catalog_multi_model_contract.sh` executes the real image
  entrypoint in bootstrap-only mode and proves that the active and seeded models
  receive metadata.
