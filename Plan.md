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
  - `dgx-spark-agentic-stack-4xu` (inspiration NemoClaw/OpenShell: gateway toujours actif + sous-agents OpenClaw isoles dans un sandbox dedie par session) [OPEN]
- Beads (OpenClaw config split):
  - `dgx-spark-agentic-stack-lhm` (separer config immuable, overlay valide et etat writable pour OpenClaw) [OPEN]
- Beads (OpenClaw approvals egress interactives):
  - `dgx-spark-agentic-stack-e0q` (ajouter une queue d'approbation operateur par destination egress + workflow `agent openclaw approvals`) [OPEN]
- Beads (ComfyUI persistence rootless-dev):
  - `dgx-spark-agentic-stack-0ik` (ComfyUI: persister toute l'arborescence avec un mount hote unique) [OPEN]

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
- Follow-up `dgx-spark-agentic-stack-0ik`: remplacer les mounts ComfyUI fragmentes (`models/input/output/user/custom_nodes`) par un mount persistant unique couvrant toute l'arborescence runtime ComfyUI, puis aligner doctor/tests/runbooks.
- Follow-up `dgx-spark-agentic-stack-qcy`: basculer OpenClaw du module optional vers le core `agent` (activation via `agent up core`, doctor/release/rollback/tests/docs alignés).
- Follow-up `dgx-spark-agentic-stack-4xu`: faire evoluer OpenClaw vers un modele a deux plans:
  - control-plane toujours actif (`optional-openclaw` + `optional-openclaw-gateway`),
  - execution-plane isole par session/sous-agent (sandbox dedie, reutilise pendant la session puis expire),
  - avec inspiration NemoClaw/OpenShell sur l'isolation par session, sans reprendre les choix d'auth plus faibles de NemoClaw.
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
