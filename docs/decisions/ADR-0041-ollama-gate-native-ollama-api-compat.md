# ADR-0041: Exposer l'API Ollama native via ollama-gate

## Status
Accepted

## Context
Le gate exposait principalement une API compatible OpenAI (`/v1/*`), mais pas les endpoints Ollama natifs (`/api/*`).
Dans ce mode, certains clients configures pour parler Ollama directement (notamment OpenWebUI en mode Ollama) ne pouvaient pas lister les modeles via la gate.

## Decision
- Etendre `deployments/gate/app.py` avec des endpoints Ollama natifs proxifies:
  - `GET /api/version`
  - `GET /api/tags`
  - `POST /api/show`
  - `POST /api/generate`
  - `POST /api/chat`
  - `POST /api/embeddings`
- Conserver les proprietes du gate sur ces endpoints:
  - discipline de concurrence/queue (slot unique + timeout),
  - logs structures avec metadata de routage,
  - headers de trace `X-Gate-*`.
- Appliquer le routage backend habituel par modele; refuser explicitement (`501`) un backend non-Ollama pour les endpoints `/api/*`.
- Ajouter un controle de non-regression dans `tests/D1_gate_up_metrics.sh` pour verifier `GET /api/tags`.

## Consequences
- `ollama-gate` peut servir a la fois les clients OpenAI-compatibles et les clients Ollama natifs.
- La liste des modeles via API Ollama est disponible sur la gate (`/api/tags`) au lieu d'un `404`.
- Les modeles restent necessaires cote Ollama: si aucun modele n'est installe, `/api/tags` renvoie toujours `{"models":[]}`.
