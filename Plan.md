# Plan - dgx-spark-agentic-stack-5bz

## Objective
Basculer le modèle local par défaut vers une cible plus fiable pour le tool-calling multi-agents, porter la fenêtre de contexte au maximum du modèle (avec contrôle ressources), ajouter un test fonctionnel 5 agents sur opérations fichiers, puis renforcer la compatibilité des intégrations agents avec les contrats Ollama (approche "inspiration launch/config", sans copier l'implémentation CLI Ollama), incluant la remontée d'usages/tokens réels et une trajectoire complète OpenClaw.

## Tracking
- Beads: `dgx-spark-agentic-stack-5bz`
- Beads (compat agents Ollama):
  - `dgx-spark-agentic-stack-3xx` (gate tools/tool_choice + tool_calls)
  - `dgx-spark-agentic-stack-eta` (usages/tokens réels sur endpoints compat)
  - `dgx-spark-agentic-stack-p1i` (Claude env `ANTHROPIC_AUTH_TOKEN`)
  - `dgx-spark-agentic-stack-m3z` (OpenWebUI gate-only par defaut)
  - `dgx-spark-agentic-stack-ygu` (veille drift upstream Ollama)
  - `dgx-spark-agentic-stack-7gw` (matrice opencode/openclaw/openhands/vibestral)
  - `dgx-spark-agentic-stack-a5m` (enforcement opencode/vibestral via gate)
  - `dgx-spark-agentic-stack-ik6` (OpenClaw complet inspire Ollama launch)
  - `dgx-spark-agentic-stack-b32` (run D8/E2 sur stack compose démarrée)

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
  - exposer des compteurs `usage`/tokens réels (pas synthétiques) sur `/v1/chat/completions`, `/v1/responses`, `/v1/messages`,
  - aligner Claude Code avec `ANTHROPIC_AUTH_TOKEN` (en gardant la rétrocompatibilité),
  - supprimer le bypass direct OpenWebUI -> Ollama en mode par défaut.
- Mettre en place une veille automatisée de drift sur docs/intégrations Ollama.
- Vérifier explicitement `opencode`, `openclaw`, `openhands`, `vibestral` (support launch upstream vs adapter interne).
- Verrouiller et vérifier le passage exclusif de `opencode` et `vibestral` via `ollama-gate` (doctor + tests + preuves logs gate).
- Ajouter l'implémentation complète OpenClaw inspirée du contrat observable `ollama launch openclaw`:
  - profil d'intégration versionné,
  - bootstrap config/env,
  - endpoints/auth/audit/sandbox alignés,
  - tests E2 de contrat et de non-régression.

## Steps
1. Mettre à jour les defaults runtime/compose/entrypoints.
2. Étendre l’onboarding (nouvelle option CLI + prompt + export env).
3. Implémenter les vérifications doctor modèle/contexte/ressources.
4. Ajouter le test `tests/L7_default_model_tool_call_fs_ops.sh`.
5. Mettre à jour README/tests existants (`00_onboarding_*`, `L5/L6`, protocol compat).
6. Valider localement les scripts de test ciblés.
7. Introduire une matrice/version de profils d'intégration agents (Codex/Claude/OpenCode/OpenClaw/OpenHands/Vibestral), avec statut "launch-supported" vs "adapter interne".
8. Implémenter côté gate le passage `tools/tool_choice` + mapping de `tool_calls` sur les endpoints compatibles.
9. Implémenter la propagation et l'exposition d'usages/tokens réels sur les endpoints compat du gate (et supprimer les usages synthétiques silencieux).
10. Aligner le bootstrap Claude avec `ANTHROPIC_AUTH_TOKEN` + tests de non-régression.
11. Passer OpenWebUI en mode gate-only par défaut et rendre l'accès direct Ollama explicitement opt-in.
12. Ajouter un verrouillage explicite opencode/vibestral -> gate-only avec vérifications doctor/tests/logs.
13. Implémenter la trajectoire OpenClaw complète inspirée `ollama launch openclaw` (profil + runtime + tests + docs).
14. Ajouter une veille automatisée de drift (job planifié + issue Beads auto en cas d'écart contractuel upstream).
15. Finaliser avec tests ciblés, commit atomique, `bd sync`, push.

## Progress (2026-03-05)
- Step 9 (partiel): endpoints compat gate migrés vers `usage` calculé depuis upstream (`/v1/chat/completions`, `/v1/responses`, `/v1/messages`) + suppression des `usage` synthétiques `0`.
- Step 9 (partiel): `/v1/embeddings` n’expose plus de `usage` synthétique; `usage` renvoyé uniquement si observé upstream.
- Step 10 (fait): bootstrap/env Claude aligné avec `ANTHROPIC_AUTH_TOKEN` (`entrypoint`, onboarding, tests).
- Step 12 (partiel): vérifications renforcées `opencode`/`vibestral` via `ollama-gate` dans `doctor` et `E2_agents_confinement`.
- Reste à faire: exécution des tests d’intégration `D8`/`E2` sur stack démarrée (non exécutable ici car services compose absents).
