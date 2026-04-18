# ADR-0109 - Etendre la parite des endpoints Ollama natifs dans `ollama-gate`

## Status
Accepted

## Context
Le gate exposait deja une partie de l'API Ollama native (`/api/version`, `/api/tags`, `/api/ps`, `/api/show`, `/api/generate`, `/api/chat`, `/api/embeddings`), mais plusieurs endpoints utilises par des clients Ollama n'etaient pas proxifies.

Les endpoints manquants identifies etaient:
- `POST /api/pull`
- `POST /api/push`
- `POST /api/create`
- `DELETE /api/delete`
- `POST /api/copy`
- `/api/blobs/:digest`
- `POST /api/embed` (distinct de `/api/embeddings`)

## Decision
- Ajouter ces endpoints dans `deployments/gate/app.py`.
- Les faire passer par `proxy_ollama_api` pour conserver les garde-fous existants:
  - file d'attente/concurrence,
  - logs structures gate,
  - en-tetes de trace `X-Gate-*`,
  - routage backend modele + refus explicite si backend non-Ollama.
- Etendre le proxy pour supporter un payload binaire brut (necessaire pour `POST /api/blobs/:digest`) tout en gardant le support JSON des routes existantes.
- Ajouter un test d'integration dedie (`tests/D15_gate_ollama_native_admin_endpoints.sh`) avec backend mock.

## Consequences
- Les clients Ollama natifs disposent d'un sous-ensemble plus complet via `ollama-gate`.
- Les operations de gestion de modeles et blobs restent soumises aux controles de la gate (pas de bypass).
- Le comportement de `POST /api/blobs/:digest` est un proxy minimal (payload brut + content-type), suffisant pour la compatibilite attendue en mode rootless-dev.
