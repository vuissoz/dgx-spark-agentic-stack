# ADR-0047: Enrichissement metadata de /v1/models dans ollama-gate

## Status
Accepted

## Context
`ollama-gate` expose deja `/v1/models` pour les clients OpenAI-compatibles, mais la reponse etait minimale (`id/object/owned_by`).
Plusieurs clients/outils beneficiaient de metadonnees supplementaires non sensibles (digest, famille, quantization, etc.) pour ameliorer l'interoperabilite et l'observabilite sans changer de endpoint.

## Decision
- Conserver la compatibilite de structure (`object=list`, `data[]`, champs `id/object/owned_by`).
- Enrichir chaque modele retourne par `/v1/models` avec un objet `metadata` non sensible et deterministe.
- Pour backend Ollama:
  - source: `ollama /api/tags`,
  - exposer quand disponible: `digest`, `size_bytes`, `modified_at`, `family`, `families`, `parameter_size`, `quantization_level`, `format`, `parent_model`.
- Pour backend OpenAI/OpenRouter:
  - conserver les champs standards principaux et ajouter `metadata` avec provenance backend/provider.
- Les metadata manquantes ne doivent jamais faire echouer l'endpoint.

## Consequences
- Les clients qui n'utilisent que `id` restent compatibles.
- Les clients avances peuvent exploiter des metadata de modeles via un endpoint unique `ollama-gate /v1/models`.
- Aucune exposition de secret n'est ajoutee.
