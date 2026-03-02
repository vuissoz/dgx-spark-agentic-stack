# ADR-0048: Bootstrap catalogue modele local pour Codex

## Status
Accepted

## Context
En profile `rootless-dev`, `agentic-codex` peut utiliser un modele local Ollama (ex: `qwen3.5:35b`) via `ollama-gate`.

Le fichier `~/.codex/config.toml` etait initialise avec `model` + `model_provider`, mais sans `model_catalog_json`.
Pour un slug non connu du catalogue embarque Codex, le CLI journalise:
`Model metadata ... not found` et bascule en metadata fallback.

Effets observes:
- warning au demarrage/exec,
- metadata potentiellement degradees (capabilities, contexte, comportements modeles).

## Decision
- Le bootstrap de `agentic-codex` devient idempotent et gere un bloc "managed" dans `~/.codex/config.toml`.
- Ce bloc impose:
  - `model = AGENTIC_DEFAULT_MODEL`,
  - `model_provider = "ollama_gate"`,
  - `model_catalog_json = /state/bootstrap/codex-model-catalog.json`,
  - provider `ollama_gate` (`base_url`, `wire_api=responses`).
- Un catalogue JSON local est genere dans `/state/bootstrap/codex-model-catalog.json` avec une entree explicite pour `AGENTIC_DEFAULT_MODEL`.
- Le reste du `config.toml` (ex: sections `projects`) est preserve.

## Consequences
- `qwen3.5:35b` (et tout `AGENTIC_DEFAULT_MODEL` local similaire) est resolu avec metadata explicites, sans fallback warning.
- Le bootstrap reste deterministic au redemarrage et apres changement de `AGENTIC_DEFAULT_MODEL`.
- Un nouveau test e2e (`tests/L6_codex_model_catalog.sh`) valide:
  - presence/coherence config + catalog,
  - execution `codex exec` locale sans warning fallback metadata.
