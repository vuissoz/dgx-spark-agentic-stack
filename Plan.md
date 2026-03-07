# Plan - dgx-spark-agentic-stack-5bz

## Objective
Basculer le modèle local par défaut vers une cible plus fiable pour le tool-calling multi-agents, porter la fenêtre de contexte au maximum du modèle (avec contrôle ressources), ajouter un test fonctionnel 5 agents sur opérations fichiers, puis renforcer la compatibilité des intégrations agents avec les contrats Ollama (approche "inspiration launch/config", sans copier l'implémentation CLI Ollama), incluant la remontée d'usages/tokens réels et une trajectoire complète OpenClaw.

## Tracking
- Beads: `dgx-spark-agentic-stack-5bz`
- Beads (compat agents Ollama):
  - `dgx-spark-agentic-stack-3xx` (gate tools/tool_choice + tool_calls) [CLOSED]
  - `dgx-spark-agentic-stack-eta` (usages/tokens réels sur endpoints compat) [CLOSED]
  - `dgx-spark-agentic-stack-p1i` (Claude env `ANTHROPIC_AUTH_TOKEN`) [CLOSED]
  - `dgx-spark-agentic-stack-m3z` (OpenWebUI gate-only par defaut) [CLOSED]
  - `dgx-spark-agentic-stack-ygu` (veille drift upstream Ollama) [CLOSED]
  - `dgx-spark-agentic-stack-7gw` (matrice opencode/openclaw/openhands/vibestral) [CLOSED]
  - `dgx-spark-agentic-stack-a5m` (enforcement opencode/vibestral via gate) [CLOSED]
  - `dgx-spark-agentic-stack-ik6` (OpenClaw complet inspire Ollama launch) [CLOSED]
  - `dgx-spark-agentic-stack-b32` (run D8/E2 sur stack compose démarrée) [CLOSED]

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

## Progress (2026-03-06, etat reel)
- Step 1-6: completes (baseline `qwen3-coder`, onboarding/context, doctor checks, L7, updates docs/tests, validations ciblees).
- Step 7: complete via `dgx-spark-agentic-stack-7gw`:
  - matrice versionnee publiee: `docs/runbooks/ollama-agent-integration-matrix.md` + `docs/runbooks/ollama-agent-integration-matrix.v1.json`,
  - ecarts assumes explicites (`launch-supported` vs `adapter-internal`),
  - tests dedies ajoutes:
    - `tests/L8_ollama_launch_alignment_contracts.sh` (opencode/openclaw),
    - `tests/L9_ollama_internal_adapter_contracts.sh` (openhands/vibestral).
- Step 9: complete via `dgx-spark-agentic-stack-eta`:
  - `/v1/chat/completions`, `/v1/responses`, `/v1/messages` exposent des usages derives de l'upstream.
  - suppression des usages synthetiques silencieux a `0`.
  - `/v1/embeddings` n'expose `usage` que si observe upstream.
- Step 10: complete via `dgx-spark-agentic-stack-p1i`:
  - `ANTHROPIC_AUTH_TOKEN` ajoute au bootstrap/onboarding et verifie dans tests/doctor.
- Step 12: complete via `dgx-spark-agentic-stack-a5m`:
  - enforcement opencode/vibestral via gate dans doctor + E2.
  - preuve automatisee de trafic dans `/gate/logs/gate.jsonl` (session unique, endpoint, statut 2xx).
- Step 14: complete via `dgx-spark-agentic-stack-ygu`:
  - ajout du watcher `agent ollama-drift watch` (invariants + hash drift sur docs upstream Ollama),
  - rapport runtime + code retour explicite en cas de drift,
  - flux Beads automatique (issue create/update + commentaire dedupe),
  - planification hebdo rootless (`agent ollama-drift schedule`, systemd user timer avec fallback cron).
- Step 13: complete via `dgx-spark-agentic-stack-ik6`:
  - profil OpenClaw versionne bootstrappe (`integration-profile.v1/current`) et consomme par runtime OpenClaw/sandbox,
  - enforcement runtime des preconditions profile (env requis, policy proxy/allowlist, endpoints launch-inspired),
  - extension des endpoints de contrat (`/v1/profile`, aliases DM/webhook/tool execute) + audit/correlation conserves,
  - validations renforcees dans `agent up optional` et `agent doctor`,
  - extension E2 `K1_openclaw` (setup profile, appel nominal, refus non autorise, drift de contrat OpenClaw).
- Validation integration associee complete via `dgx-spark-agentic-stack-b32`:
  - `D8_gate_protocol_compat`: PASS
  - `E2_agents_confinement`: PASS (runtime rootless-dev avec `AGENTIC_AGENT_NO_NEW_PRIVILEGES=false`).

## Remaining Work (open)
- Step 15: finalisation globale (tests cibles, commit atomique, `bd sync`, push).

## Sync Note (2026-03-07)
- Step 8 (`dgx-spark-agentic-stack-3xx`) ferme le 2026-03-06.
- Step 11 (`dgx-spark-agentic-stack-m3z`) ferme le 2026-03-06.
