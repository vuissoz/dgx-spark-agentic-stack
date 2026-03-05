# Plan - dgx-spark-agentic-stack-5bz

## Objective
Basculer le modèle local par défaut vers une cible plus fiable pour le tool-calling multi-agents, porter la fenêtre de contexte au maximum du modèle (avec contrôle ressources), ajouter un test fonctionnel 5 agents sur opérations fichiers, puis renforcer la compatibilité des intégrations agents avec les contrats Ollama (approche "inspiration launch/config", sans copier l'implémentation CLI Ollama).

## Tracking
- Beads: `dgx-spark-agentic-stack-5bz`
- Beads (compat agents Ollama):
  - `dgx-spark-agentic-stack-3xx` (gate tools/tool_choice + tool_calls)
  - `dgx-spark-agentic-stack-p1i` (Claude env `ANTHROPIC_AUTH_TOKEN`)
  - `dgx-spark-agentic-stack-m3z` (OpenWebUI gate-only par defaut)
  - `dgx-spark-agentic-stack-ygu` (veille drift upstream Ollama)
  - `dgx-spark-agentic-stack-7gw` (matrice opencode/openclaw/openhands/vibestral)

## Scope
- Changer `AGENTIC_DEFAULT_MODEL` par défaut vers `qwen3-coder:30b`.
- Ajouter `AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW` (onboarding + runtime) et propagation vers `OLLAMA_CONTEXT_LENGTH`.
- Vérifier en `agent doctor`:
  - cohérence contexte demandé vs capacité modèle,
  - adéquation mémoire locale (budget Ollama) pour le contexte configuré.
- Ajouter un test `L7` qui valide, via le modèle local par défaut, les 4 opérations suivantes sur 5 agents (`claude`, `codex`, `opencode`, `vibestral`, `openhands`):
  - écrire un fichier,
  - lire le fichier,
  - exécuter un fichier `python.py`,
  - supprimer le fichier.
- Mettre à jour docs et tests onboarding/régression liés au modèle par défaut.
- Ajouter une couche de compat intégrations agents inspirée des contrats Ollama:
  - profils de configuration par agent (source de vérité versionnée),
  - chemins protocole explicites (`/v1/chat/completions`, `/v1/responses`, `/v1/messages`),
  - variables/env générées de manière déterministe par agent.
- Corriger les écarts majeurs de compat:
  - relayer `tools`/`tool_choice` et renvoyer `tool_calls` cohérents côté gate,
  - aligner Claude Code avec `ANTHROPIC_AUTH_TOKEN` (en gardant la rétrocompatibilité),
  - supprimer le bypass direct OpenWebUI -> Ollama en mode par défaut.
- Mettre en place une veille automatisée de drift sur docs/intégrations Ollama.
- Vérifier explicitement `opencode`, `openclaw`, `openhands`, `vibestral` (support launch upstream vs adapter interne).

## Steps
1. Mettre à jour les defaults runtime/compose/entrypoints.
2. Étendre l’onboarding (nouvelle option CLI + prompt + export env).
3. Implémenter les vérifications doctor modèle/contexte/ressources.
4. Ajouter le test `tests/L7_default_model_tool_call_fs_ops.sh`.
5. Mettre à jour README/tests existants (`00_onboarding_*`, `L5/L6`, protocol compat).
6. Valider localement les scripts de test ciblés.
7. Introduire une matrice/version de profils d'intégration agents (Codex/Claude/OpenCode/OpenClaw/OpenHands/Vibestral), avec statut "launch-supported" vs "adapter interne".
8. Implémenter côté gate le passage `tools/tool_choice` + mapping de `tool_calls` sur les endpoints compatibles.
9. Aligner le bootstrap Claude avec `ANTHROPIC_AUTH_TOKEN` + tests de non-régression.
10. Passer OpenWebUI en mode gate-only par défaut et rendre l'accès direct Ollama explicitement opt-in.
11. Ajouter une veille automatisée de drift (job planifié + issue Beads auto en cas d'écart contractuel upstream).
12. Finaliser avec tests ciblés, commit atomique, `bd sync`, push.
