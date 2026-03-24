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
  - `dgx-spark-agentic-stack-0hk` (relay public Telegram/WhatsApp -> queue/file -> injection locale OpenClaw) [CLOSED]
- Beads (dashboard OpenClaw):
  - `dgx-spark-agentic-stack-j01` (dashboard operateur OpenClaw accessible via tunnel SSH/Tailscale, loopback-only) [CLOSED]
- Beads (wizard CLI OpenClaw en conteneur):
  - `dgx-spark-agentic-stack-69e` (parite wizard `openclaw onboard/configure/agents add` dans un conteneur OpenClaw avec workspace persistant) [CLOSED]
- Beads (tests setup OpenClaw CLI):
  - `dgx-spark-agentic-stack-x00` (couverture tests setup/config OpenClaw CLI + variantes) [CLOSED]
- Beads (OpenClaw sandboxes de session):
  - `dgx-spark-agentic-stack-4xu` (inspiration NemoClaw/OpenShell: gateway toujours actif + sous-agents OpenClaw isoles dans un sandbox dedie par session) [CLOSED]
- Beads (OpenClaw config split):
  - `dgx-spark-agentic-stack-lhm` (separer config immuable, overlay valide et etat writable pour OpenClaw) [OPEN]
- Beads (OpenClaw approvals egress interactives):
  - `dgx-spark-agentic-stack-e0q` (ajouter une queue d'approbation operateur par destination egress + workflow `agent openclaw approvals`) [OPEN]
- Beads (Resolution deterministe des `latest`):
  - `dgx-spark-agentic-stack-fcb` (resoudre les valeurs `latest` en versions figees au moment de `agent update` et tracer demande vs valeur resolue) [OPEN]
- Beads (Registre d'etat OpenClaw):
  - `dgx-spark-agentic-stack-oop` (ajouter un registre persistant des sessions/sandboxes OpenClaw pour `agent ls` et `agent doctor`) [OPEN]
- Beads (Dualite API interne / CLI operateur OpenClaw):
  - `dgx-spark-agentic-stack-0n8` (gerer les sous-agents via une API interne OpenClaw et separer cette logique de la surface CLI operateur `agent openclaw ...`) [OPEN]
- Beads (Contrat de module OpenClaw):
  - `dgx-spark-agentic-stack-zj4` (formaliser un blueprint/manifest OpenClaw pour les fichiers, ports, auth, routes provider et compatibilites CLI) [OPEN]
- Beads (Plugin UX in-chat OpenClaw):
  - `dgx-spark-agentic-stack-irt` (ajouter une commande slash OpenClaw de statut dans le chat, branchee au registre/runtime sans fuite de secrets) [OPEN]
- Beads (ComfyUI persistence rootless-dev):
  - `dgx-spark-agentic-stack-0ik` (ComfyUI: persister toute l'arborescence avec un mount hote unique) [CLOSED]

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

## Addendum (2026-03-24, recommandation contexte max-fit Ollama)
- Beads `dgx-spark-agentic-stack-goh`: derivee partagee du contexte maximal qui tient dans `AGENTIC_LIMIT_OLLAMA_MEM` a partir des metadonnees Ollama du modele. [CLOSED]
  - Correctif: facteur commun `scripts/lib/ollama_context.sh` pour calculer taille modele, KV-cache/token, memoire requise et `estimated_max_fitting_context`.
  - `agent doctor`: remonte maintenant explicitement le contexte maximal estime qui tient dans le budget memoire et propose la valeur a appliquer a `AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW` / `OLLAMA_CONTEXT_LENGTH` / `AGENTIC_GOOSE_CONTEXT_LIMIT` quand le contexte configure est trop grand.
  - `agent onboard`: reutilise le meme calcul; en non-interactif il auto-selectionne la valeur recommandee quand aucune fenetre explicite n'est fournie, et en interactif il repropose la valeur estimee apres saisie de `AGENTIC_LIMIT_OLLAMA_MEM`.
  - Couverture: ajout du test hermetique `tests/00_ollama_context_estimator.sh` + extension `tests/00_onboarding_env_wizard.sh` pour un cas `nemotron-cascade-2:30b` / `110g` => `108883`.

## Addendum (2026-03-24, seuils de compaction exposes aux agents)
- Beads `dgx-spark-agentic-stack-wj3`: informer explicitement les agents des seuils de compaction derives du budget de contexte effectif. [OPEN]
  - Besoin: aujourd'hui la stack expose la fenetre de contexte mais pas de seuil explicite indiquant quand un agent doit commencer a compacter/synthetiser son historique avant d'approcher la limite dure.
  - Cible: derivation stack-side d'au moins deux bornes coherentes par modele/runtime:
    - seuil de compaction "soft" (debut de resume/compactage),
    - seuil "danger" / proche limite (avant depassement du budget effectif).
  - Implementation visee:
    - etendre `scripts/lib/ollama_context.sh` pour deriver une politique de seuils a partir de `estimated_max_fitting_context`,
    - propager ces seuils dans les configurations/runtime env exposes aux agents (`codex`, `claude`, `opencode`, `vibestral`, `openhands`, `goose` quand applicable),
    - garder `agent doctor` capable de verifier la coherence entre budget memoire, contexte effectif et seuils exposes,
    - documenter le partage des responsabilites: stack = politique/signaux, agent = compaction semantique, backend = enforcement memoire/cache.
  - Couverture attendue:
    - tests hermetiques de derivation des seuils,
    - tests onboarding/runtime verifiant l'export des seuils aux agents,
    - doc/ADR explicitant la politique par defaut (par ex. compactage a 80-90% du budget utile, zone danger a 95%).

## Remaining Work (open)
- Step 15: finalisation globale (tests cibles, commit atomique, `bd sync`, push).
- Follow-up `dgx-spark-agentic-stack-qcy`: basculer OpenClaw du module optional vers le core `agent` (activation via `agent up core`, doctor/release/rollback/tests/docs alignés).
- Follow-up `dgx-spark-agentic-stack-lhm`: separer l'etat OpenClaw en trois couches:
  - config immuable geree par la stack,
  - overlay operateur valide sur un sous-ensemble de cles safe,
  - etat runtime writable (agents/sessions/devices/cache/workspace metadata),
  - avec documentation explicite des cles immuables vs overlay-allowed.
- Follow-up `dgx-spark-agentic-stack-e0q`: ajouter une boucle d'approbation egress interactive OpenClaw au-dessus des allowlists statiques:
  - queue durable `pending/approved/denied/expired` pour les destinations non listees,
  - workflow operateur `agent openclaw approvals [list|approve|deny|promote]`,
  - approbations scope session vs promotion persistante vers artefact de config explicite,
  - audit JSONL et verifications doctor/tests associees.
- Follow-up `dgx-spark-agentic-stack-fcb`: traiter `latest` comme une politique de resolution et non comme une version deploiement:
  - resolution des valeurs `latest` supportees au moment de `agent update`,
  - capture release de la valeur demandee vs valeur resolue,
  - deploiement/rollback appuyes sur la valeur resolue/pinnee,
  - doctor/tests/docs pour detecter les flottants non resolus dans les releases actives.
- Follow-up `dgx-spark-agentic-stack-oop`: introduire un modele d'etat OpenClaw premier-classe:
  - registre persistant des sessions/sandboxes OpenClaw,
  - champs operateur minimaux: current/default, model, provider, policy set, creation, workspace, last health,
  - integration dans `agent ls`, `agent doctor` et les futurs workflows OpenClaw,
  - sans stocker de donnees sensibles.
- Follow-up `dgx-spark-agentic-stack-0n8`: separer les surfaces de controle OpenClaw:
  - API interne de lifecycle des sandboxes/sous-agents consommee par le main agent OpenClaw,
  - surface CLI operateur distincte, adossee au meme runtime/registre, avec des commandes de type:
    - `agent openclaw status [--json]`
    - `agent openclaw policy list|add`
    - `agent openclaw model set <id>`
    - `agent openclaw sandbox ls|attach|destroy`
  - sans exposer `./agent` comme dependance du main agent.
- Follow-up `dgx-spark-agentic-stack-zj4`: ajouter un contrat de module OpenClaw type blueprint/manifest:
  - manifeste versionne des fichiers/configs requis, ports/endpoints attendus, mode d'auth, routes provider permises et version(s) CLI compatibles,
  - etapes lifecycle explicites de type `resolve`, `verify digest`, `plan`, `apply`, `status`,
  - integration avec `agent doctor` et/ou `agent update` pour signaler les incoherences de module,
  - articulation documentee entre contrat OpenClaw et artefacts globaux de release, sans y stocker de secrets.
- Follow-up `dgx-spark-agentic-stack-irt`: ajouter une commande in-chat OpenClaw de type plugin UX:
  - commande slash minimale de type `/openclaw status` (ou equivalent) dans l'interface OpenClaw,
  - lecture d'un etat deja expose par le registre/runtime/API interne OpenClaw,
  - sortie utile pour l'operateur: statut module, sandbox/session courant, modele/provider, sante recente,
  - sans contourner la separation entre confinement, API interne machine et CLI operateur.

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

## Addendum (2026-03-10, OpenClaw vers core agent)
- Beads `dgx-spark-agentic-stack-qcy`: demander la bascule OpenClaw de `optional` vers le périmètre `core`.
  - Cible: `agent up core` doit démarrer OpenClaw sans dépendre de `AGENTIC_OPTIONAL_MODULES=openclaw`.
  - Contraintes: conserver les invariants CDC (loopback-only hôte, pas de `docker.sock`, hardening conteneur, secrets runtime, egress contrôlé).
  - Impacts attendus: aligner `agent ls/logs/stop`, `agent doctor`, `agent update`, `agent rollback` et la doc d'onboarding avec ce nouveau placement.

## Addendum (2026-03-11, dashboard OpenClaw via tunnel SSH/Tailscale)
- Beads `dgx-spark-agentic-stack-j01`: implémenter un dashboard OpenClaw opérateur dans la stack.
  - Besoin: combler l'écart entre la commande dashboard upstream OpenClaw et le runtime actuel orienté API locale.
  - Cible: dashboard accessible uniquement via bind loopback hôte et tunnel SSH/Tailscale (même posture d'accès que les autres interfaces opérateur).
  - Contraintes: aucune exposition 0.0.0.0, pas de `docker.sock`, intégration `agent doctor` + `agent update` + `agent rollback`.

## Addendum (2026-03-11, wizard CLI OpenClaw en conteneur)
- Beads `dgx-spark-agentic-stack-69e`: demander la parite operateur avec le wizard upstream OpenClaw directement dans le conteneur.
  - Besoin: pouvoir lancer en session conteneur les commandes `openclaw onboard`, `openclaw configure`, `openclaw agents add <name>` comme decrit dans la doc OpenClaw.
  - Cible: conteneur OpenClaw operable comme les autres agents (session shell/tmux), avec workspace persistant et configuration standard de la stack.
  - Contraintes: conventions `/srv/agentic/openclaw/{state,logs,workspaces}`, posture loopback-only, hardening conteneur standard, integration `agent doctor` + `agent update` + `agent rollback`.

## Addendum (2026-03-11, livraison relay/dashboard/CLI wizard OpenClaw)
- Beads `dgx-spark-agentic-stack-0hk`, `dgx-spark-agentic-stack-j01`, `dgx-spark-agentic-stack-69e`, `dgx-spark-agentic-stack-x00`: implementation livree.
  - Runtime:
    - ajout du service `optional-openclaw-relay` (ingest provider signe, queue durable `pending/done/dead`, retries/backoff, dead-letter, audit JSONL),
    - ajout du dashboard OpenClaw (`/dashboard`, `/v1/dashboard/status`),
    - ajout d'un CLI OpenClaw conteneurise (`openclaw onboard/configure/agents add`) avec persistance sous `/state/cli` et `/workspace`.
  - Orchestration/doctor:
    - `agent openclaw` expose les endpoints dashboard+relay et ouvre une session shell projet sur workspace persistant,
    - `agent stop openclaw` inclut relay+sandbox,
    - `agent doctor` verifie contrat CLI/workspace/dashboard/relay (loopback bindings + endpoint queue relay + profile/config files).
  - Docs/tests:
    - runbook mis a jour: `docs/runbooks/openclaw-onboarding-rootless-dev.md` (wizard en conteneur, tunnel SSH/Tailscale Linux/macOS/Windows, verifs relay),
    - test E2 dedie: `tests/K6_openclaw_cli_dashboard_relay.sh` (CLI setup/config + erreur actionable, dashboard, relay happy/deny/duplicate/dead-letter),
    - regression K1 maintenue (`tests/K1_openclaw.sh`).

## Addendum (2026-03-12, requirement ComfyUI persistence scope)
- Beads `dgx-spark-agentic-stack-0ik`: en rootless-dev, les mutations ComfyUI peuvent impacter toute l'arborescence (pas seulement `input/output`).
  - Exigence ajoutee: basculer vers un mount hote persistant unique pour toute l'arborescence runtime ComfyUI (point canonique sous `${AGENTIC_ROOT}/comfyui`).
  - Impact attendu: persistance deterministe des changements ComfyUI hors `input/output`, avec alignement compose/bootstrap/doctor/tests/runbooks.

## Addendum (2026-03-24, ComfyUI runtime root + CUDA arm64/rootless-dev)
- Beads `dgx-spark-agentic-stack-0ik` et `dgx-spark-agentic-stack-6nn`: livraison conjointe.
  - Persistence:
    - le service `comfyui` utilise maintenant un mount hote unique `${AGENTIC_ROOT}/comfyui:/comfyui`,
    - les chemins mutables du source tree (`models`, `input`, `output`, `user`, `custom_nodes`) sont symlinkes vers `/comfyui/*`,
    - `agent forget comfyui` cible desormais `${AGENTIC_ROOT}/comfyui` comme unite canonique.
  - Contrat CUDA:
    - l'image enregistre un diagnostic build/runtime PyTorch,
    - l'entrypoint publie `${AGENTIC_ROOT}/comfyui/user/agentic-runtime/torch-runtime.json`,
    - en `arm64/rootless-dev`, la politique expose `effective` si `torch.cuda.is_available()` est vrai, sinon `unsupported-explicit` avec fallback `--cpu`.
  - Verification:
    - `tests/I1_comfyui.sh` verifie le mount unique, l'absence des anciens mounts fragmentes, le symlink `custom_nodes` et le diagnostic CUDA,
    - `agent doctor` controle le contrat mount unique + diagnostic CUDA sur `arm64/rootless-dev`,
    - validation locale observee le 2026-03-24: backend CUDA ComfyUI effectif sur la machine de dev `aarch64`.

## Addendum (2026-03-13, Prometheus metrics for TCP forwarder)
- Beads `dgx-spark-agentic-stack-wlx`: exporter des metriques Prometheus natives pour les forwarders TCP OpenClaw (notamment le forwarder `optional-openclaw-gateway`).
  - Objectif:
    - rendre observable le trafic du forwarder (connexions, bytes entrants/sortants, erreurs) depuis Prometheus/Grafana.
  - Plan d'implementation:
    1. Remplacer/etendre `deployments/optional/tcp_forward.py` pour exposer un endpoint HTTP `/metrics` (format Prometheus text exposition).
    2. Ajouter des compteurs/gauges minimaux:
       - `tcp_forward_connections_total`,
       - `tcp_forward_connections_active`,
       - `tcp_forward_bytes_in_total`,
       - `tcp_forward_bytes_out_total`,
       - `tcp_forward_connection_errors_total`.
    3. Etendre la definition `optional-openclaw-gateway` pour exposer le port metrics en interne uniquement (pas de bind host public supplementaire).
    4. Ajouter un scrape target Prometheus pour ce endpoint et verifier sa presence via `api/v1/targets`.
    5. Ajouter/mettre a jour un dashboard Grafana (ou panel dans dashboard existant) pour visualiser debit, connexions actives, erreurs.
    6. Etendre `agent doctor` (chemin optional OpenClaw) pour verifier que le endpoint `/metrics` est disponible quand le module est actif.
    7. Ajouter un test de non-regression (suite K/OpenClaw) validant exposition metrics + scrape Prometheus.
    8. Mettre a jour les runbooks OpenClaw/observabilite.
  - Contraintes:
    - conserver le bind loopback-only cote hote,
    - ne pas exposer de secrets dans labels/logs/metrics,
    - ne pas relacher le hardening conteneur.

## Addendum (2026-03-13, onboarding retention and disk occupation policy)
- Beads `dgx-spark-agentic-stack-im5`: ajouter dans l'onboarding des questions explicites pour la retention maximale et l'occupation disque maximale, puis appliquer ces politiques au runtime.
  - Objectif:
    - rendre la retention observabilite parametrique des le premier setup operateur, avec enforcement technique (pas uniquement documentaire).
  - Plan d'implementation:
    1. Etendre `agent onboard` (wizard + non-interactif) avec deux nouveaux parametres:
       - retention maximale (ex: `15d`, `30d`),
       - occupation disque maximale (ex: `50GB`, `200GB`).
    2. Definir des variables runtime explicites exportees dans `runtime.env` (noms a figer pendant implementation).
    3. Propager la retention vers Prometheus:
       - `--storage.tsdb.retention.time`,
       - `--storage.tsdb.retention.size`.
    4. Propager la retention/limites vers Loki:
       - retention policy (ex: `limits_config.retention_period`),
       - compactor/cleanup si necessaire selon mode Loki utilise.
    5. Aligner la politique de logs conteneurs (rotation `json-file` max-size/max-file) avec le budget disque global choisi, sans regressions de securite.
    6. Ajouter des verifications `agent doctor`:
       - presence des valeurs configurees,
       - coherence format/borne,
       - correspondance entre onboarding, compose effectif et runtime.
    7. Ajouter tests de non-regression onboarding + compose rendering + checks observabilite.
    8. Mettre a jour README et runbooks ops (changement de policy apres deploiement, impact rollback).
  - Contraintes:
    - conserver binds loopback-only,
    - ne pas exposer de secrets dans logs/metrics,
    - garder une trajectoire rollback deterministe (release manifests).

## Addendum (2026-03-22, OpenClaw subagents sandboxes per-session)
- Beads `dgx-spark-agentic-stack-4xu`: faire evoluer l'implementation OpenClaw en s'inspirant de NemoClaw/OpenShell pour l'isolation des sous-agents.
  - Constat actuel:
    - `optional-openclaw-gateway` et `optional-openclaw` fournissent deja un plan de controle toujours actif adapte a l'usage operateur,
    - `optional-openclaw-sandbox` reste un service Compose long-vivant partage, donc pas un vrai boundary de sandbox par session/sous-agent.
  - Cible:
    - conserver le gateway OpenClaw toujours actif et sans reconfiguration a chaque session,
    - introduire un execution-plane capable de creer un sandbox dedie par session de sous-agent / runtime outils,
    - reutiliser ce sandbox pendant toute la session, puis expirer/nettoyer sur timeout ou fermeture explicite,
    - exposer un etat operateur (doctor/status/logs) montrant quels sandboxes de session existent et leur rattachement aux sessions.
  - Inspirations NemoClaw a reprendre:
    - separation nette control-plane / execution-plane,
    - isolation par session,
    - trajectoire config immuable / state mutable pour limiter le tampering runtime.
  - Inspirations NemoClaw a ne pas reprendre:
    - auth gateway affaiblie,
    - auto-approval implicite des devices,
    - secrets/token gates figes dans l'image.
  - Impacts attendus:
    - evolution de `optional-openclaw-sandbox` vers un orchestrateur/launcher de sandboxes de session plutot qu'un backend partage,
    - extension de `agent doctor` + tests K/OpenClaw pour verifier creation/reutilisation/expiration des sandboxes de session,
    - ADR dedie expliquant le modele cible et les ecarts volontaires avec NemoClaw.

## Addendum (2026-03-22, OpenClaw config immuable / overlay valide / etat writable)
- Beads `dgx-spark-agentic-stack-lhm`: clarifier et durcir le modele d'etat OpenClaw en separant les couches de configuration et de runtime.
  - Constat actuel:
    - `OPENCLAW_HOME=/state/cli/openclaw-home` et `OPENCLAW_CONFIG_PATH=/state/cli/openclaw-home/openclaw.json` pointent vers une arborescence writable unique,
    - des reglages stack-owned (auth gateway, routage provider, attentes SecretRef, parametres sensibles) peuvent cohabiter avec l'etat mutable OpenClaw.
  - Cible:
    - couche 1 `immutable`:
      - configuration geree par la stack et non reecrivable au runtime,
      - typiquement: auth/bind du gateway, provider/routage local, endpoints sensibles, attentes SecretRef, policy sandbox/egress stack-owned ;
    - couche 2 `validated overlay`:
      - personnalisation operateur permise uniquement sur un sous-ensemble de cles explicitement autorisees,
      - validation stricte avant merge dans la config effective ;
    - couche 3 `writable state`:
      - etat runtime mutable: agents, sessions, devices, cache, metadata workspace, extensions/skills state si autorises.
  - Effet recherche:
    - empecher qu'un workflow OpenClaw normal ou un agent reecrive silencieusement la configuration de securite/routage appartenant a la stack,
    - conserver les workflows operateur utiles (`openclaw agents add`, workspaces, sessions) sans reintroduire une config monolithique writable.
  - Livrables attendus:
    - layout d'arborescence cible documente,
    - bootstrap/runtime alignes sur cette separation,
    - doctor/tests/docs listant clairement ce qui est immuable, overlay-allowed et writable.

## Addendum (2026-03-22, OpenClaw approvals egress interactives)
- Beads `dgx-spark-agentic-stack-e0q`: completer le modele allowlist-only actuel par une boucle d'approbation operateur pour les destinations egress non prevues.
  - Constat actuel:
    - OpenClaw s'appuie sur des allowlists statiques/policies explicites,
    - une destination non prevue est bloquee, mais il n'existe pas de queue operateur ni de workflow de decision runtime comparable a l'idee NemoClaw/OpenShell.
  - Cible:
    - garder les allowlists statiques comme baseline de securite,
    - bloquer par defaut toute destination inconnue puis materialiser la tentative dans une queue durable,
    - fournir un workflow `agent openclaw approvals` pour:
      - lister les demandes pending,
      - approuver temporairement dans un scope controle (session),
      - refuser explicitement,
      - promouvoir une destination vers un artefact de config persistant et tracable.
  - Exigences:
    - aucune ouverture implicite de trafic hors du scope de la decision,
    - audit JSONL des demandes et des decisions,
    - pas de secrets dans la queue, les logs ou les commentaires,
    - doctor/tests/docs couvrant la queue, les promotions persistantes et l'absence de regression des controles egress.

## Addendum (2026-03-22, resolution deterministe des valeurs `latest`)
- Beads `dgx-spark-agentic-stack-fcb`: garder l'ergonomie operateur `latest` tout en figeant les versions effectivement deployees.
  - Constat actuel:
    - la stack enregistre deja digests/images/runtime inputs dans les releases,
    - mais certains composants acceptent des valeurs `latest` qui restent une intention flottante plutot qu'une version resolue explicitement tracee.
  - Cible:
    - `latest` devient une politique de resolution au moment de `agent update`,
    - chaque composant supporte est resolu une seule fois vers une version concrete upstream,
    - la release enregistre:
      - la valeur demandee (`latest`),
      - la valeur resolue (ex: `2026.3.11`),
      - toute verification associee disponible (checksum/signature/source de resolution) quand elle existe,
    - le deploiement effectif et le rollback reutilisent la valeur resolue/pinnee, pas l'alias flottant.
  - Portee:
    - OpenClaw en priorite,
    - puis tout autre point de la stack utilisant `latest` (images, install scripts, specs d'outils) selon inventaire explicite.
  - Exigences:
    - aucune re-resolution implicite pendant un simple `agent up` sur une release deja figee,
    - doctor/tests detectent les releases actives contenant encore des flottants non resolus la ou la politique impose une resolution,
    - docs/runbooks explicitent que `latest` est une intention de tracking, pas une version deploiement.

## Addendum (2026-03-22, registre d'etat OpenClaw)
- Beads `dgx-spark-agentic-stack-oop`: ajouter un registre d'etat persistant pour les sessions/sandboxes OpenClaw afin d'ameliorer l'operabilite.
  - Constat actuel:
    - la stack expose les services OpenClaw et des checks ponctuels,
    - mais ne maintient pas un registre explicite permettant de repondre simplement a: quelle session est courante/par defaut, quel modele/provider/policy est applique, quel workspace est attache, quelle est la derniere sante observee.
  - Cible:
    - registre local/persistant, plus leger que le modele NemoClaw complet,
    - champs minimaux:
      - `current` / `default`,
      - `model`,
      - `provider`,
      - `policy_set`,
      - `created_at`,
      - `workspace`,
      - `last_health`,
      - `expires_at` ou equivalent si le runtime introduit des sandboxes de session.
  - Usages vises:
    - enrichir `agent ls`,
    - permettre a `agent doctor` de verifier la coherence de l'etat OpenClaw actif,
    - fournir une base de contrat pour les futurs workflows OpenClaw (approvals, sandboxes de session, model/status).
  - Exigences:
    - aucune donnee sensible dans le registre,
    - emplacement/runtime documentes,
    - docs/tests alignes si le registre devient un contrat supporte.

## Addendum (2026-03-22, dualite API interne / CLI operateur OpenClaw)
- Beads `dgx-spark-agentic-stack-0n8`: introduire une separation explicite entre pilotage machine des sous-agents OpenClaw et surface d'operations humaine.
  - Constat actuel:
    - une future surface `agent openclaw ...` est utile pour l'operateur,
    - mais elle ne constitue pas le bon mecanisme pour que le main agent OpenClaw cree/attache/detruise ses sous-agents,
    - il faut eviter toute dependance du main agent a `./agent` ou a un wrapper shell hote.
  - Cible:
    - surface 1 `internal sandbox manager API`:
      - API interne de confiance pour le lifecycle des sous-agents/sandboxes OpenClaw,
      - operations cibles: create, get, list, delete, attach-or-reuse selon session,
      - consommee par le main agent OpenClaw ;
    - surface 2 `operator CLI`:
      - commandes d'administration/inspection lisibles par l'operateur,
      - cibles minimales:
        - `agent openclaw status [--json]`
        - `agent openclaw policy list|add`
        - `agent openclaw model set <id>`
        - `agent openclaw sandbox ls|attach|destroy`
      - branchee sur le meme registre/runtime que l'API interne.
  - Effet recherche:
    - le main agent OpenClaw pilote ses sous-agents via une interface machine appropriee,
    - l'operateur dispose d'une surface dediee pour observer, debugger et reprendre la main sans ouvrir un contournement de securite.
  - Exigences:
    - aucune invocation de `./agent` par le main agent OpenClaw,
    - compatibilite avec les futurs sandboxes de session et le registre d'etat OpenClaw,
    - `agent doctor` able de verifier la coherence entre API interne, registre et surface operateur,
    - pas de secret ni de capacite privilegiee inutile dans les commandes operateur exposees.

## Addendum (2026-03-22, contrat de module OpenClaw type blueprint/manifest)
- Beads `dgx-spark-agentic-stack-zj4`: formaliser un contrat de module OpenClaw inspire du lifecycle blueprint de NemoClaw.
  - Constat actuel:
    - la stack dispose deja d'une tracabilite globale des releases et des digests deploiement,
    - mais OpenClaw ne dispose pas d'un contrat de module explicite et versionne qui decrive ses preconditions, ses artefacts et ses compatibilites,
    - il manque donc une source unique pour verifier fichiers requis, ports, mode d'auth, routes provider autorisees et version CLI supportee.
  - Cible:
    - introduire un manifest/module contract OpenClaw versionne qui decrit au minimum:
      - les fichiers/configs requis,
      - les ports/endpoints attendus,
      - le mode d'auth supporte,
      - les routes/provider base URLs permises,
      - les versions CLI compatibles,
      - les etapes lifecycle de type `resolve`, `verify digest`, `plan`, `apply`, `status` ;
    - permettre a `agent doctor`, `agent update` ou au flux de deploiement de s'appuyer sur ce contrat pour signaler une incoherence de module.
  - Effet recherche:
    - rendre le module OpenClaw auditable comme unite fonctionnelle,
    - mieux lier les artefacts globaux de release aux attentes specifiques du module OpenClaw,
    - preparer une base de validation stable pour les futures evolutions OpenClaw (sandboxes, approvals, model/policy surface).
  - Exigences:
    - ne pas dupliquer inutilement les artefacts de release globaux,
    - ne stocker aucun secret dans le manifeste,
    - documenter clairement la relation entre contrat de module, release globale et checks `doctor`.

## Addendum (2026-03-22, plugin UX in-chat OpenClaw)
- Beads `dgx-spark-agentic-stack-irt`: ajouter une commande in-chat OpenClaw inspiree du `/nemoclaw status` de NemoClaw.
  - Constat actuel:
    - la stack prepare une surface operateur `agent openclaw ...` et des APIs/etats OpenClaw plus riches,
    - mais ne prevoit pas encore de commande de chat pour obtenir rapidement un statut operationnel sans sortir dans le shell,
    - cette fonctionnalite est une amelioration d'ergonomie, pas un mecanisme de confinement.
  - Cible:
    - introduire une commande slash minimaliste de type `/openclaw status` dans l'interface de chat OpenClaw,
    - brancher cette commande sur le registre d'etat, le runtime ou l'API interne OpenClaw deja exposes par la stack,
    - afficher un resume sans secret du module OpenClaw:
      - sandbox/session courant,
      - modele/provider actif,
      - derniere sante connue,
      - eventuels indicateurs d'etat operateur utiles.
  - Effet recherche:
    - reduire le besoin de quitter le chat pour des diagnostics simples,
    - ameliorer l'operabilite sans ajouter de droits ou de voies de contournement,
    - reutiliser les futurs contrats d'etat OpenClaw au lieu d'introduire une source de verite parallele.
  - Exigences:
    - ne pas exposer de secrets, tokens, chemins sensibles ou details privilegies,
    - ne pas contourner la separation entre main agent, API interne et CLI operateur,
    - documenter explicitement que cette UX vient apres les travaux de securite et de confinement.
