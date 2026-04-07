# ADR-0054: Matrice agents/integrations Ollama (Step 7)

## Status
Accepted

## Context
Le suivi `dgx-spark-agentic-stack-7gw` demande une formalisation explicite, versionnee et testee de la compatibilite Ollama pour:
- `opencode`,
- `openclaw`,
- `openhands`,
- `vibestral`,
- `hermes`.

Contrainte principale:
- `opencode` et `openclaw` ont un contrat upstream visible via `ollama launch`.
- `openhands`, `vibestral` et `hermes` n'ont pas un contrat upstream `ollama launch` equivalent et reposent sur des adapters internes du stack.

Sans matrice formelle:
- la frontiere entre "alignement launch-supported" et "adapter interne" reste implicite,
- les regressions de contrat deviennent difficiles a detecter/reviewer.

## Decision
1. Ajouter une matrice versionnee machine-readable:
   - `docs/runbooks/ollama-agent-integration-matrix.v1.json`.
2. Publier le runbook humain associe:
   - `docs/runbooks/ollama-agent-integration-matrix.md`.
3. Declarer explicitement, par entree:
   - source de contrat,
   - mode de configuration,
   - endpoint cible,
   - variables requises,
   - statut support upstream (`launch-supported` ou `adapter-internal`),
   - ecarts assumes.
4. Ajouter des tests de contrat dedies:
   - `tests/L8_ollama_launch_alignment_contracts.sh` pour `opencode/openclaw`,
   - `tests/L9_ollama_internal_adapter_contracts.sh` pour `openhands/vibestral/hermes`.
5. Etendre le watcher de drift Ollama avec un filtre de scope:
   - `--sources <csv>` pour verifier un sous-ensemble de contrats upstream.

## Consequences
- Le statut de support par agent est auditable et non ambigu.
- Les ecarts assumes entre upstream et adapter interne sont documentes et testes.
- Les campagnes de verification peuvent cibler finement un sous-ensemble de contrats (`opencode/openclaw`) sans relancer toute la matrice upstream.
