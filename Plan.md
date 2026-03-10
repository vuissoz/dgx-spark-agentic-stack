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
  - `dgx-spark-agentic-stack-p94` (onboarding secret `huggingface.token` pour Flux/ComfyUI) [CLOSED]
- Beads (relay webhook providers OpenClaw):
  - `dgx-spark-agentic-stack-0hk` (relay public Telegram/WhatsApp -> queue/file -> injection locale OpenClaw) [OPEN]

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
- Ajouter une trajectoire webhook provider "production-safe" pour OpenClaw, sans exposition publique directe du service local:
  - endpoint public relay (hors OpenClaw local),
  - persistance queue/file durable,
  - worker sortant DGX qui injecte vers `http://127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}/v1/webhooks/dm`.

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
- Follow-up `dgx-spark-agentic-stack-6nn`: valider une trajectoire CUDA effective pour ComfyUI (arm64 rootless-dev) ou formaliser une politique unsupported explicite avec test/alerte opérateur.
- Follow-up `dgx-spark-agentic-stack-0hk`: implémenter le relay webhook provider (Telegram/WhatsApp) via queue/file + consommation sortante et injection locale OpenClaw, avec tests E2 et runbook.

## Sync Note (2026-03-07)
- Step 8 (`dgx-spark-agentic-stack-3xx`) ferme le 2026-03-06.
- Step 11 (`dgx-spark-agentic-stack-m3z`) ferme le 2026-03-06.

## Addendum (2026-03-07, rootless-dev UI fiabilisation)
- Beads `dgx-spark-agentic-stack-3yi` (OpenHands): nouvelle conversation peut redémarrer le conteneur (`oom`/`exit 137`) quand les process sandboxes s'accumulent.
  - Correctif: garde-fou de capacité sur sandboxes process (`OH_PROCESS_SANDBOX_MAX_ACTIVE`, défaut 2), poll startup non nul, et limite mémoire OpenHands dédiée relevée (`AGENTIC_LIMIT_OPENHANDS_MEM`).
  - Vérif: `tests/H2_openhands.sh` étendu pour créer plusieurs conversations et détecter tout restart pendant le flux.
- Beads `dgx-spark-agentic-stack-8cx` (ComfyUI/Flux): journal terminal bloqué et bootstrap Flux.1-dev non guidé.
  - Correctif: proxy loopback WebSocket (`/ws`) corrigé, image ComfyUI alignée PyTorch CUDA, commande opérateur `agent comfyui flux-1-dev` + manifeste/layout/téléchargement HF.
  - Correctif complémentaire: `scripts/comfyui_flux_setup.sh` exécute désormais les blocs Python via `docker exec -i` (stdin attaché) pour garantir l'exécution réelle des probes/downloads.
  - Vérif: `tests/I1_comfyui.sh` vérifie handshake WebSocket 101, `tests/I2_comfyui_flux_bootstrap.sh` couvre bootstrap Flux + exécution effective du chemin `--download` (erreur HF token attendue sans secret).

## Addendum (2026-03-08, onboarding secret Hugging Face)
- Beads `dgx-spark-agentic-stack-p94`: ajout du token HF dans le bootstrap secrets onboarding.
  - Correctif: `agent onboard` accepte `--huggingface-token` et, en interactif, propose `huggingface.token (optional, for ComfyUI gated HF models)`.
  - Stockage: `${AGENTIC_ROOT}/secrets/runtime/huggingface.token` (mode `0600`).
  - Ergonomie Flux: `agent comfyui flux-1-dev --download` consomme automatiquement ce fichier si `--hf-token-file` n'est pas fourni.
  - Vérif: extensions tests onboarding (`00_onboarding_env_wizard`, `00_onboarding_full_setup_wizard`) pour couvrir le secret HF.

## Addendum (2026-03-10, rootless-dev onboarding OpenClaw)
- Beads `dgx-spark-agentic-stack-s0m`: runbook d'onboarding OpenClaw cible `rootless-dev` pour cette stack.
  - Ajout du guide: `docs/runbooks/openclaw-onboarding-rootless-dev.md`.
  - Contenu: mapping des commandes upstream OpenClaw (`openclaw onboard`, `openclaw gateway ...`) vers le workflow stack (`./agent onboard`, `AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional`, `./agent doctor`, `./agent test K`), avec conventions de sécurité locale (`127.0.0.1`, secrets runtime, allowlists).
  - Références: `https://openclaw.ai/` et `https://docs.openclaw.ai/start/getting-started`.

## Addendum (2026-03-10, webhook providers OpenClaw)
- Beads `dgx-spark-agentic-stack-0hk`: Telegram/WhatsApp exigent un endpoint webhook joignable et stable, distinct de l'ingress loopback OpenClaw.
  - Décision: conserver `127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}` comme point d'entrée interne uniquement.
  - Implémentation visée: relay public -> queue/file durable -> consumer sortant DGX -> `POST /v1/webhooks/dm` en local loopback.
  - Exigences associées: validation signature provider, idempotence/retries, audit JSONL corrélé, tests E2 (nominal + erreurs + reprise).
