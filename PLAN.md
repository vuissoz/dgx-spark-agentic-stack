# DGX Spark Canonical Plan

Ce fichier est la **source de vérité unique** du dépôt pour le plan DGX Spark. Il fusionne l’ancien `PLAN.md` (roadmap d’implémentation A→L) et l’ancien `Plan.md` (tracking d’exécution, umbrella Beads, addenda et follow-ups). Il ne doit plus exister qu’un seul fichier de plan dans le repo.

Ce plan reste conçu pour être exécuté par un agent de coding : chaque sous-tâche doit produire des artefacts concrets (fichiers, scripts, compose) et **chaque sous-tâche a un test automatique** avec critères d’acceptation binaires. On n’enchaîne pas une étape tant que ses tests ne sont pas verts.

Hypothèses d’exécution : hôte Linux (DGX Spark), Docker Engine + Docker Compose v2, NVIDIA Container Toolkit, accès distant via Tailscale/SSH. Invariant : **aucun service web n’écoute sur `0.0.0.0`** (bind hôte sur `127.0.0.1` uniquement). Les conteneurs communiquent via un réseau Docker privé.

## Comment lire ce plan

- `Current State` : où en est réellement le dépôt aujourd’hui, avec statuts Beads normalisés.
- `Profils d’exécution` puis sections `0` à `L` : roadmap détaillée et exigences d’implémentation/test.
- `Définition “terminé”` et `Ordre d’exécution imposé` : critères finaux et chemin critique.

## Current State

### Canonical tracking merge

- L’ancien fichier `Plan.md` est absorbé ici.
- Les statuts Beads ci-dessous sont normalisés d’après le tracker local au `2026-03-28`.
- Quand un ancien addendum de `Plan.md` indiquait `[OPEN]` mais que Beads est désormais `closed`, le statut canonique est celui de Beads.

### Active umbrella merged from former `Plan.md`

- Umbrella : `dgx-spark-agentic-stack-5bz` (`closed`)
- Objectif exécuté :
  - basculer le modèle local par défaut vers une cible plus fiable pour le tool-calling multi-agents ;
  - pousser la fenêtre de contexte au maximum utile du modèle avec contrôle ressources ;
  - ajouter le test fonctionnel 5 agents sur opérations fichiers ;
  - renforcer la compatibilité des intégrations agents avec les contrats Ollama ;
  - livrer la trajectoire OpenClaw inspirée de `ollama launch openclaw`.

### Scope recap merged from former `Plan.md`

- `AGENTIC_DEFAULT_MODEL` par défaut vers `qwen3-coder:30b`.
- `AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW` ajouté et propagé vers `OLLAMA_CONTEXT_LENGTH`.
- `agent doctor` vérifie la cohérence contexte/capacité modèle/mémoire.
- `tests/L7_default_model_tool_call_fs_ops.sh` couvre les opérations fichier sur `claude`, `codex`, `opencode`, `vibestral`, `openhands`.
- Suivi ouvert `dgx-spark-agentic-stack-yzk0` : ajouter un test d’intégration end-to-end piloté par dépôt sur `codex`, `openclaw`, `claude`, `opencode`, `openhands`, `pi-mono`, `goose`, `vibestral`, avec runner commun, collecte d’artefacts et doctor final.
- La compatibilité agents inspirée des contrats Ollama inclut :
  - profils de configuration par agent versionnés ;
  - chemins explicites `/v1/chat/completions`, `/v1/responses`, `/v1/messages` ;
  - variables/env générées de manière déterministe.
- Les écarts majeurs de compat couverts incluent :
  - `tools` / `tool_choice` / `tool_calls` ;
  - `usage` / tokens réels ;
  - `ANTHROPIC_AUTH_TOKEN` pour Claude ;
  - suppression du bypass direct OpenWebUI -> Ollama par défaut.
- La trajectoire OpenClaw couvre :
  - profil d’intégration versionné ;
  - bootstrap config/env ;
  - endpoints/auth/audit/sandbox alignés ;
  - tests E2 et non-régression ;
  - relay webhook provider “production-safe”.

### Umbrella step status

| Step | Status | Beads / note |
| --- | --- | --- |
| 1 | complete | umbrella `dgx-spark-agentic-stack-5bz` |
| 2 | complete | umbrella `dgx-spark-agentic-stack-5bz` |
| 3 | complete | umbrella `dgx-spark-agentic-stack-5bz` |
| 4 | complete | umbrella `dgx-spark-agentic-stack-5bz` |
| 5 | complete | umbrella `dgx-spark-agentic-stack-5bz` |
| 6 | complete | umbrella `dgx-spark-agentic-stack-5bz` |
| 7 | complete | `dgx-spark-agentic-stack-7gw` |
| 8 | complete | `dgx-spark-agentic-stack-3xx` |
| 9 | complete | `dgx-spark-agentic-stack-eta` |
| 10 | complete | `dgx-spark-agentic-stack-p1i` |
| 11 | complete | `dgx-spark-agentic-stack-m3z` |
| 12 | complete | `dgx-spark-agentic-stack-a5m` |
| 13 | complete | `dgx-spark-agentic-stack-ik6` |
| 14 | complete | `dgx-spark-agentic-stack-ygu` |
| 15 | complete for umbrella scope | validations `dgx-spark-agentic-stack-b32`, `dgx-spark-agentic-stack-de9`, doc refresh `dgx-spark-agentic-stack-mvzt` |

### Delivered tracking from former `Plan.md`

- Core Ollama / compat agents:
  - `dgx-spark-agentic-stack-5bz` : modèle local par défaut, onboarding contexte, test 5 agents FS ops.
  - `dgx-spark-agentic-stack-3xx` : `tools` / `tool_choice` / `tool_calls` sur endpoints compatibles.
  - `dgx-spark-agentic-stack-eta` : usages/tokens réels sur `/v1/chat/completions`, `/v1/responses`, `/v1/messages`.
  - `dgx-spark-agentic-stack-p1i` : bootstrap Claude aligné sur `ANTHROPIC_AUTH_TOKEN`.
  - `dgx-spark-agentic-stack-m3z` : OpenWebUI gate-only par défaut.
  - `dgx-spark-agentic-stack-ygu` : veille automatisée de drift upstream Ollama.
  - `dgx-spark-agentic-stack-1r0` : commande opérateur `agent ollama unload <model>` pour décharger explicitement un modèle local avec traçabilité.
  - `dgx-spark-agentic-stack-7gw` : matrice d’intégration `opencode/openclaw/openhands/vibestral`.
  - `dgx-spark-agentic-stack-a5m` : enforcement opencode/vibestral via `ollama-gate`.
  - `dgx-spark-agentic-stack-b32` : validation D8/E2 sur stack compose démarrée.
  - `dgx-spark-agentic-stack-goh` : estimation du contexte maximal qui tient dans le budget mémoire.
  - `dgx-spark-agentic-stack-ahl` : arbitrage dynamique `ollama|trtllm|both|remote`.
  - `dgx-spark-agentic-stack-de9` : clôture des gaps résiduels du plan umbrella.
- OpenClaw livré :
  - `dgx-spark-agentic-stack-0hk` : relay webhook provider -> queue/file -> injection locale.
  - `dgx-spark-agentic-stack-j01` : dashboard opérateur via tunnel SSH/Tailscale, loopback-only.
  - `dgx-spark-agentic-stack-69e` : parité wizard CLI en conteneur.
  - `dgx-spark-agentic-stack-x00` : couverture tests setup/config OpenClaw CLI.
  - `dgx-spark-agentic-stack-4xu` : sandboxes dédiés par session.
  - `dgx-spark-agentic-stack-qcy` : OpenClaw basculé du module optional vers le core `agent`.
  - `dgx-spark-agentic-stack-lhm` : séparation config immuable / overlay valide / état writable.
  - `dgx-spark-agentic-stack-e0q` : approvals interactives d’egress par destination.
  - `dgx-spark-agentic-stack-fcb` : résolution déterministe des valeurs `latest`.
  - `dgx-spark-agentic-stack-oop` : registre d’état persistant sessions/sandboxes.
  - `dgx-spark-agentic-stack-0n8` : dualité API interne / CLI opérateur.
  - `dgx-spark-agentic-stack-zj4` : blueprint/manifest de module OpenClaw.
  - `dgx-spark-agentic-stack-irt` : commande in-chat de statut OpenClaw.
  - `dgx-spark-agentic-stack-433` : vrai Control UI OpenClaw sur `127.0.0.1:18789`.
  - `dgx-spark-agentic-stack-qik` : provider bridges stack-managed pour Telegram/Slack/Discord + bootstrap WhatsApp.
  - `dgx-spark-agentic-stack-u326` reste ouvert : `agent openclaw init` stack-managed et réparation idempotente ne sont pas encore clos.
- UI / ComfyUI / docs / onboarding :
  - `dgx-spark-agentic-stack-3yi` : garde-fou OpenHands contre restart/OOM au démarrage de nouvelles conversations.
  - `dgx-spark-agentic-stack-8cx` : proxy WebSocket ComfyUI et bootstrap Flux.1-dev clarifiés.
  - `dgx-spark-agentic-stack-p94` : secret `huggingface.token` dans l’onboarding.
  - `dgx-spark-agentic-stack-s0m` : runbook `rootless-dev` OpenClaw.
  - `dgx-spark-agentic-stack-0ik` : persistance ComfyUI sur mount hôte unique.
  - `dgx-spark-agentic-stack-6nn` : contrat CUDA arm64/rootless-dev explicité.
  - `dgx-spark-agentic-stack-mvzt` : `README.md` devenu landing page anglaise concise, références EN/FR préservées.
- Observabilité / policy:
  - `dgx-spark-agentic-stack-im5` reste ouvert : politique de rétention et d’occupation disque à intégrer à l’onboarding/runtime.
  - `dgx-spark-agentic-stack-wlx` est `in_progress` : métriques Prometheus natives pour forwarders TCP OpenClaw.
  - `dgx-spark-agentic-stack-cx9` est resolu : l'onboarding exporte maintenant `COMPOSE_PROFILES` et `TRTLLM_MODELS`, avec prompt explicite d'activation TRT.
  - `dgx-spark-agentic-stack-wav3` : le défaut `agent onboard` pour `TRTLLM_MODELS` pointe maintenant vers le slug Hugging Face `NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4`, avec fallback runtime cohérent et vérification `agent doctor` exécutée sur le profil actif.
  - `dgx-spark-agentic-stack-vb7p` reste ouvert : valider un premier `hello` complet Nemotron-3-Super après warm-up initial du backend TRT-LLM natif.
  - `dgx-spark-agentic-stack-c8n` : ajout d'un mode `TRTLLM_NATIVE_MODEL_POLICY=strict-nvfp4-local-only` pour DGX Spark, avec répertoire local NVFP4 imposé et absence de fallback silencieux vers HF/FP8.

### Remaining active follow-ups merged from former `Plan.md`

| Issue | Status | Remaining work |
| --- | --- | --- |
| `dgx-spark-agentic-stack-wj3` | open | publier des seuils de compaction “soft” / “danger” dérivés du budget de contexte et les exposer aux agents |
| `dgx-spark-agentic-stack-u326` | open | livrer `agent openclaw init` comme chemin stack-managed d’onboarding/réparation |
| `dgx-spark-agentic-stack-im5` | open | demander rétention max + budget disque max en onboarding et les appliquer au runtime |
| `dgx-spark-agentic-stack-wlx` | in_progress | exposer et scrapper des métriques Prometheus pour les forwarders TCP OpenClaw |
| `dgx-spark-agentic-stack-zu7n` | open | ajouter une forge Git interne loopback-only avec comptes dédiés pour chaque agent et gestion opérateur documentée |
| `dgx-spark-agentic-stack-yzk0` | open | livrer un test de stack end-to-end piloté par dépôt sur `codex`, `openclaw`, `claude`, `opencode`, `openhands`, `pi-mono`, `goose`, `vibestral`, avec runner commun, artefacts unifiés et doctor final |

## Profils d’exécution (obligatoires)

Le plan doit rester exécutable via deux profils explicites :

- `strict-prod` (défaut) :
  - cible CDC stricte ;
  - root hôte requis ;
  - racine runtime : `/srv/agentic` ;
  - enforcement `DOCKER-USER` requis ;
  - `agent doctor` échoue sur tout écart structurant.
- `rootless-dev` :
  - mode développement local sans privilèges root sur l’hôte principal ;
  - racine runtime : `${HOME}/.local/share/agentic` (sauf override) ;
  - pas d’attente `DOCKER-USER` (check/apply désactivés par défaut) ;
  - `agent doctor` conserve les checks applicables (bind loopback, santé services, hardening conteneurs), et dégrade en warning les contrôles hôte impossibles sans root.

Sélection du profil :
- `AGENTIC_PROFILE=strict-prod` (défaut)
- `AGENTIC_PROFILE=rootless-dev`

Règle de conformité : toute exigence CDC “hôte root” reste normative en `strict-prod`; `rootless-dev` est un mode d’implémentation/développement, pas un substitut de conformité finale.

### Option pratique : VM dédiée pour tester `strict-prod`

Un troisième chemin d’exécution est autorisé pour les tests d’intégration “prod-like” sans modifier l’hôte principal :

- créer une **VM dédiée** (où l’opérateur a les droits root) ;
- exécuter le profil `strict-prod` dans la VM ;
- garder les mêmes garde-fous (`/srv/agentic`, `DOCKER-USER`, bind loopback, doctor strict).
- la VM doit avoir un **accès GPU** (passthrough/équivalent selon hyperviseur) validé par `nvidia-smi` dans la VM ;
- la **taille mémoire de la VM** doit être **paramétrable** (variable/flag explicite dans le provisionnement, pas une valeur figée en dur).

Contrainte mémoire (Ollama) :

- si la VM n’a pas assez de RAM pour des modèles 7B+, utiliser un **petit modèle** uniquement pour les smoke tests (ex: 0.5B à 3B quantisé) ;
- ce mode valide la posture stack/ops (A→L), pas la performance/capacité cible d’un modèle lourd.

---

## 0) Convention “repo” + harness de tests (à créer avant A)

### 0.1 Arborescence cible sur l’hôte
Racine runtime selon profil :
- `strict-prod` : `/srv/agentic/`
- `rootless-dev` : `${HOME}/.local/share/agentic/`

Le contenu attendu reste identique :

- `/srv/agentic/deployments/` : compose, scripts, snapshots (rollback), policies
- `/srv/agentic/bin/agent` : point d’entrée opérateur (commande unique)
- `/srv/agentic/tests/` : tests automatiques (A→L)
- `/srv/agentic/secrets/` : secrets runtime + logs rotation
- `/srv/agentic/{ollama,gate,proxy,dns,openwebui,openhands,comfyui,rag,monitoring}/`
- `/srv/agentic/{claude,codex,opencode,vibestral}/{state,logs,workspaces}/`
- `/srv/agentic/optional/git/{config,state,logs,db,repositories,bootstrap}/`
- `AGENTIC_AGENT_WORKSPACES_ROOT` peut séparer les workspaces agents du reste :
  - `strict-prod` par défaut : `${AGENTIC_ROOT}` (donc `${AGENTIC_ROOT}/<tool>/workspaces`)
  - `rootless-dev` par défaut : `${AGENTIC_ROOT}/agent-workspaces` (donc `${AGENTIC_AGENT_WORKSPACES_ROOT}/<tool>/workspaces`)
- `/srv/agentic/shared-ro/` et `/srv/agentic/shared-rw/`

### 0.2 Standard “tests”
Chaque test est un script shell idempotent dans `<AGENTIC_ROOT>/tests/` :
- `tests/A_*.sh … tests/L_*.sh` + `tests/V_*.sh`
- retour code `0` si OK, `!=0` sinon
- output lisible (OK/FAIL) + option : JSON dans `deployments/test-reports/<ts>/`

Créer `tests/lib/common.sh` (helpers) :
- `fail()`, `ok()`, `assert_cmd()`, `assert_no_public_bind()`, `assert_container_security()`, `assert_proxy_enforced()`, etc.

### 0.3 Commande unique `agent` (squelette immédiat)
Créer `<AGENTIC_ROOT>/bin/agent` avec au minimum :
- `agent up <core|agents|ui|obs|rag|optional>`
- `agent down <…>`
- `agent ps`
- `agent logs <service>`
- `agent llm mode <local|hybrid|remote>` (pilotage providers externes/local sans casser les agents)
- `agent llm backend <ollama|trtllm|both|remote>` (politique backend desiree + arbitrage runtime)
- `agent llm test-mode [on|off]` (mode test runtime du gate pour campagnes automatisées)
- `agent forget <target> --yes` (reset destructif ciblé d’un domaine persistant)
- `agent backup <run|list|restore <snapshot_id>>` (snapshots incrémentaux des données persistantes + config non-secrète)
- `agent ollama-link` + `agent rollback ollama-link <backup_id|latest>` (gestion store modèles rootless)
- `agent ollama-models [status|rw|ro]` (pilotage mode de mount des modèles Ollama)
- `agent sudo-mode [status|on|off]` (élévation intra-conteneur agents, contrôlée et réversible)
- `agent vm create ...` + `agent vm test ...` + `agent vm cleanup ...` (campagne `strict-prod` en VM dédiée)
- `agent test <A|B|…|L|V|all>` (exécute le(s) script(s) correspondants)
- `agent doctor` (agrégat de conformité “doit rester vert”)
- `agent profile` (affiche le profil effectif + chemins/réseaux)

**Test automatique** : `tests/00_harness.sh`
- vérifie que `agent test A` appelle bien un script
- vérifie que `agent doctor` existe et retourne `!=0` si aucun compose n’est déployé (mode “pas prêt” explicite)

### 0.4 Script d’onboarding débutant (variables d’environnement)
**Implémentation**
- créer un wizard interactif `deployments/bootstrap/onboarding_env.sh` (ou `agent onboard`) qui :
  - explique en langage simple le rôle de chaque variable d’environnement requise avant déploiement ;
  - pose des questions une par une avec valeur par défaut affichée ;
  - accepte `Entrée` comme réponse “garder la valeur par défaut” ;
  - valide les chemins saisis (existants ou créables) et refuse les valeurs invalides avec message actionnable ;
  - génère un fichier shell sourçable (ex: `${AGENTIC_ROOT}/deployments/env.sh` ou `.runtime/env.generated.sh`, non committé) ;
  - propose en fin de wizard la commande exacte à exécuter (`source ...`) puis `./agent profile`.
- variables minimales couvertes par le wizard :
  - `AGENTIC_PROFILE` (`strict-prod` par défaut, `rootless-dev` proposé pour dev local),
  - `AGENTIC_ROOT`,
  - `AGENTIC_OPTIONAL_MODULES`,
  - `AGENTIC_AGENT_WORKSPACES_ROOT`,
  - `AGENTIC_CLAUDE_WORKSPACES_DIR`,
  - `AGENTIC_CODEX_WORKSPACES_DIR`,
  - `AGENTIC_OPENCODE_WORKSPACES_DIR`,
  - `AGENTIC_VIBESTRAL_WORKSPACES_DIR`,
  - `AGENTIC_OPENHANDS_WORKSPACES_DIR`,
  - `AGENTIC_COMPOSE_PROJECT`,
  - `AGENTIC_NETWORK`,
  - `AGENTIC_EGRESS_NETWORK`,
  - `OLLAMA_MODELS_DIR`.
- si le module `git-forge` est sélectionné dans `AGENTIC_OPTIONAL_MODULES`, le wizard couvre aussi au minimum :
  - `GIT_FORGE_HOST_PORT` (bind loopback-only côté hôte),
  - `GIT_FORGE_ADMIN_USER` (défaut : `system-manager`),
  - `GIT_FORGE_SHARED_NAMESPACE` (organisation/groupe commun pour projets partagés),
  - `GIT_FORGE_ENABLE_PUSH_CREATE` (`0/1`, désactivé par défaut),
  - chemins de secrets attendus pour le mot de passe admin initial et les credentials/tokens des comptes agents,
  - option de préconfiguration Git agents pour que le premier shell `agent <tool>` puisse faire immédiatement `git clone`/checkout sans saisie manuelle de credential.
- contraintes UX :
  - aucune question “bloquante” sans valeur par défaut ;
  - mode non interactif disponible via flags (`--profile`, `--root`, etc.) pour CI ;
  - pas d’écriture de secrets.

**Test** : `tests/00_onboarding_env_wizard.sh`
- exécution non-interactive avec réponses simulées (stdin) :
  - `Entrée` sur chaque question -> fichier généré avec valeurs par défaut attendues ;
  - override d’au moins 2 chemins -> fichier généré avec valeurs custom ;
- shellcheck/parse du fichier généré (`bash -n`) ;
- vérifie que le fichier est ignoré par git et n’inclut aucun secret.

### 0.5 Onboarding complet “type CMake/ccmake” (premier démarrage)
Suivi Beads : `dgx-spark-agentic-stack-kvs`

**Implémentation**
- étendre `agent onboard` avec une interface guidée plus ergonomique (mode “assistant de configuration” inspiré CMake/ccmake : sections claires, navigation simple, validation immédiate).
- couvrir **tout** le setup obligatoire du premier démarrage dans le même flux, sans étape cachée :
  - profil/runtime (`AGENTIC_PROFILE`, `AGENTIC_ROOT`, réseaux, project name) ;
  - bootstrap admin pour services UI activés (utilisateur admin + mot de passe via prompt masqué) ;
  - configuration réseau/egress (allowlist initiale domaines/CIDR autorisés selon politique), avec une baseline incluant les endpoints GitHub nécessaires aux agents (`github.com`, `api.github.com`, `codeload.github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`) ;
  - secrets requis par modules activés (création/génération guidée ou saisie manuelle) ;
  - si `git-forge` est activé :
    - activer le module dans `AGENTIC_OPTIONAL_MODULES`,
    - demander/valider `GIT_FORGE_HOST_PORT`, `GIT_FORGE_ADMIN_USER`, `GIT_FORGE_SHARED_NAMESPACE`, `GIT_FORGE_ENABLE_PUSH_CREATE`,
    - générer ou recueillir hors git le secret admin initial et les credentials des comptes `openclaw`, `openhands`, `comfyui`, `claude`, `codex`, `opencode`, `vibestral`, `pi-mono`, `goose`,
    - préparer la configuration Git initiale par agent (au minimum remote base URL, helper de credentials ou fichier équivalent hors git, `user.name`, `user.email`) pour qu’un premier `git clone`/checkout fonctionne dès la première connexion shell,
    - créer de manière idempotente, dès la première initialisation complète de la stack, un dépôt/projet partagé de référence pour le test E2E (ex: `eight-queens-agent-e2e`) dans la forge interne, contenant :
      - la formulation du problème des 8 reines dans le dépôt lui-même ;
      - la consigne de sortie attendue et les contraintes de vérification ;
      - la commande de test à exécuter et les critères binaires de succès/échec ;
      - un état initial volontairement non conforme ou incomplet que l’agent doit corriger en Python ;
    - protéger la branche par défaut (`main`) contre les pushes directs agents et créer/préparer une branche dédiée par agent (ex: `agent/<tool>` pour `codex`, `openclaw`, `claude`, `opencode`, `openhands`, `pi-mono`, `goose`, `vibestral`) ;
    - documenter et injecter dans la consigne standard des agents l’interdiction de pousser sur `main` : chaque agent ne doit pousser que sur sa propre branche dédiée,
    - récapituler les chemins secrets et la commande d’activation `./agent up optional`.
- sortie des secrets :
  - fichiers séparés sous `${AGENTIC_ROOT}/secrets/runtime/` uniquement ;
  - permissions strictes (`chmod 600`) ;
  - jamais écrits dans les fichiers versionnés ni affichés en clair dans les logs.
- produire un récapitulatif final “prêt à exécuter” :
  - fichiers générés,
  - modules activés,
  - commandes suivantes exactes (`agent profile`, `agent up ...`, `agent doctor`),
  - alertes bloquantes explicites si un paramètre obligatoire manque.

**Test** : `tests/00_onboarding_full_setup_wizard.sh`
- chemin interactif simulé : complète les sections runtime/admin/network/secrets et vérifie qu’aucune question obligatoire n’est contournée ;
- chemin non interactif (`--non-interactive` + flags/fichiers) : génère la même structure cible ;
- vérifie les permissions des secrets (`600`) et leur absence des artefacts versionnés/logs ;
- vérifie qu’un setup incomplet retourne un code non-zéro avec message actionnable ;
- valide que la sortie finale liste toutes les commandes post-onboarding nécessaires.

---

## A — Fondations hôte & arborescence `/srv/agentic`

### A1 Pré-requis Docker/Compose/NVIDIA
**Implémentation**
- documenter dans `deployments/README-host.md` les commandes de diag minimales
- note backlog : ajouter une commande simple `scripts/check_prereqs.sh` (ou alias `./agent prereqs`) qui vérifie la présence des prérequis opérateur (`docker`, `docker compose`, `multipass`, `nvidia-smi`, `iptables`, `setfacl`) et renvoie une sortie actionnable (OK/FAIL par dépendance).
- aucun compose à ce stade

**Test** : `tests/A1_host_prereqs.sh`
- `docker version` OK
- `docker compose version` OK
- `nvidia-smi` OK sur l’hôte
- option GPU conteneur : `docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi` OK

### A2 Création arbo + permissions
**Implémentation**
- script idempotent `deployments/bootstrap/init_fs.sh`
  - `strict-prod` : crée groupe `agentic`, crée tous les dossiers sous `/srv/agentic`, applique permissions strictes ;
  - `rootless-dev` : ne modifie pas les groupes système, crée les dossiers sous `${HOME}/.local/share/agentic` avec permissions compatibles rootless ;
  - dans les deux cas : pas de secrets world-readable.

**Test** : `tests/A2_fs_layout_permissions.sh`
- `test -d <AGENTIC_ROOT>/{deployments,bin,tests,secrets,ollama,gate,proxy,dns}` OK
- `find <AGENTIC_ROOT> -maxdepth 2 -type d -perm -0002` → **vide**
- `<AGENTIC_ROOT>/secrets` : pas accessible “others”, fichiers `600/640` selon besoin

### A3 Invariant “aucun bind 0.0.0.0”
**Implémentation**
- ajouter dans `tests/lib/common.sh` : `assert_no_public_bind()`
- intégrer `assert_no_public_bind` dans `agent doctor`

**Test** : `tests/A3_no_public_bind.sh`
- `ss -lntp` ne doit montrer **aucun** port critique (ex: 11434, 8080, 3000, 8188, 9090, 3100, 9100…) écoutant sur `0.0.0.0`

### A4 Contrôle explicite “pas de docker.sock” (statique + runtime)
Suivi Beads : `dgx-spark-agentic-stack-ao5`

**Implémentation**
- ajouter un test dédié qui valide l’invariant “pas de mount `docker.sock`” :
  - statique (`docker compose config`) sur tous les plans ;
  - runtime (`docker inspect`) sur les conteneurs du projet.
- vérifier l’absence de motifs de contournement évidents :
  - `/var/run/docker.sock`
  - `/run/docker.sock`
  - bind implicite via volume nommé pointant vers le socket hôte.

**Test** : `tests/A4_no_docker_sock_static_and_runtime.sh`
- échoue si un mount socket Docker apparaît dans la config Compose effective.
- échoue si un mount socket Docker apparaît sur un conteneur en exécution.
- passe en nominal sur baseline `core+agents+ui`.

---

## B — Noyau réseau : réseau privé, DNS interne, proxy egress, enforcement DOCKER-USER

### B1 Réseau Docker privé `agentic`
**Implémentation**
- `deployments/compose/compose.core.yml` :
  - réseau `agentic` avec `internal: true`
  - service “toolbox” minimal (busybox/alpine) pour tests réseau

**Test** : `tests/B1_network_internal.sh`
- `docker network inspect agentic` → `.Internal == true`

### B2 DNS interne (Unbound)
**Implémentation**
- ajouter service `unbound` dans `compose.core.yml` (interne uniquement)
- config dans `/srv/agentic/dns/unbound.conf`

**Test** : `tests/B2_dns_unbound.sh`
- depuis le conteneur toolbox : `drill @unbound example.com` OK
- preuve de non-dépendance DNS externe directe : requête vers `@1.1.1.1` doit échouer (si DOCKER-USER appliqué à ce stade) ou être explicitement bloquée plus tard (B4)

### B3 Proxy egress (allowlist)
**Implémentation**
- ajouter service `egress-proxy` (ex: squid/tinyproxy) dans `compose.core.yml` (interne uniquement)
- policy allowlist : `/srv/agentic/proxy/allowlist.txt`
- logs proxy : `/srv/agentic/proxy/logs/`
- inclure dans l’allowlist par défaut les endpoints GitHub nécessaires aux workflows git des agents (au minimum `github.com`, `api.github.com`, `codeload.github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`) ; option SSH explicite via `ssh.github.com:443` si activée.

**Test** : `tests/B3_proxy_policy.sh`
- depuis toolbox (sans proxy env) : `curl -fsS https://example.com` **échoue**
- depuis toolbox (avec proxy) : `curl -fsS -x http://egress-proxy:3128 https://example.com` :
  - OK si `example.com` allowlisté
  - sinon doit retourner un DENY explicite (acceptable si mode strict) + log présent
- depuis toolbox (avec proxy) : accès `https://github.com` et `https://api.github.com/meta` OK quand baseline allowlist active

### B4 DOCKER-USER : anti-bypass (DROP+LOG)
**Implémentation**
- script idempotent `deployments/net/apply_docker_user.sh`
  - chaîne DOCKER-USER : `ESTABLISHED,RELATED` ACCEPT
  - allow strict : DNS→unbound, HTTP(S)→proxy, LLM→gate (quand gate existe)
  - le reste : LOG rate-limited + DROP
- intégrer `apply_docker_user.sh` dans `agent up core` (ou `agent doctor --fix-net`)
- en `rootless-dev` : `apply/check DOCKER-USER` désactivés par défaut (pas d’échec bloquant)

**Test** : `tests/B4_docker_user_enforced.sh`
- `iptables -S DOCKER-USER` contient un DROP final + règle LOG
- tentative d’egress direct (sans proxy) échoue systématiquement
- compteur/log DOCKER-USER augmente après tentative bloquée (preuve d’enforcement)
- en `rootless-dev` : test explicitement skip (attendu)

### B5 Rollback hôte des changements `sudo` (DOCKER-USER)
**Implémentation**
- avant toute application de règles host firewall, sauvegarder l’état précédent (`iptables-save`) dans `${AGENTIC_ROOT}/deployments/host-net/backups/<ts>/`.
- fournir `deployments/net/rollback_docker_user.sh <backup_id>` :
  - restaure la chaîne `DOCKER-USER` et la chaîne dédiée `AGENTIC-DOCKER-USER` à l’état sauvegardé ;
  - retire les règles ajoutées par la stack si le backup d’origine n’en contenait pas.
- exposer via l’interface opérateur :
  - `agent net apply` (applique + crée backup),
  - `agent rollback host-net <backup_id>` (rollback déterministe côté hôte).
- journaliser chaque `apply/rollback` hôte dans `${AGENTIC_ROOT}/deployments/changes.log` avec acteur, horodatage UTC, backup_id.

**Test** : `tests/B5_host_net_rollback.sh`
- capture état initial `iptables-save` (hash),
- applique la politique DOCKER-USER,
- exécute le rollback du backup créé,
- vérifie que l’état final (`iptables-save`) est identique à l’état initial (hash égal).
- en `rootless-dev` : test explicitement skip (attendu).

### B6 Résistance anti-contournement egress depuis conteneurs agents
Suivi Beads : `dgx-spark-agentic-stack-39m`

**Implémentation**
- ajouter un test orienté conteneurs agents (pas uniquement `toolbox`) qui tente des bypass classiques :
  - requête directe sans proxy ;
  - `NO_PROXY=*` / désactivation explicite des variables proxy ;
  - tentative directe vers IP publique (pour éviter le seul contrôle DNS).
- valider en parallèle que le chemin proxy continue de fonctionner quand la destination est allowlistée.
- en `rootless-dev`, conserver le comportement de skip explicite des assertions host-root-only.

**Test** : `tests/B6_egress_bypass_resistance.sh`
- depuis au moins un conteneur agent (`agentic-codex` ou `agentic-claude`) :
  - egress direct = refus explicite ;
  - egress via proxy = succès/deny conforme à la policy allowlist.
- en `strict-prod`, preuve de blocage via règles DOCKER-USER/proxy.
- en `rootless-dev`, skip explicite des contrôles impossibles sans root.

---

## C — Inference de base : Ollama (local-only)

### C1 Déployer Ollama + volume persistant
**Implémentation**
- ajouter service `ollama` (GPU) dans `compose.core.yml`
- configurer un env `OLLAMA_MODELS_DIR` pour le mount des modèles (ex: `${OLLAMA_MODELS_DIR:-/srv/agentic/ollama/models}:/root/.ollama/models`)
- valeur locale existante à supporter sans copie : `/home/vuissoz/wkdir/open-webui/ollama_data/models/`
- bind hôte : `127.0.0.1:11434:11434`
- healthcheck HTTP `/api/version`

**Test** : `tests/C1_ollama_basic.sh`
- hôte : `curl -fsS http://127.0.0.1:11434/api/version` OK
- `ss -lntp | grep 11434` → écoute sur `127.0.0.1` uniquement
- interne : `curl -fsS http://ollama:11434/api/version` OK
- health docker : `healthy`
- `docker inspect ollama` confirme le source mount des modèles = valeur effective de `OLLAMA_MODELS_DIR` (ou fallback par défaut)

### C1b Gestion du store modèles Ollama (link rootless + mode mount)
**Implémentation**
- fournir un helper rootless `agent ollama-link` pour relier un store modèles local existant vers le chemin runtime attendu, sans copie destructive.
- fournir `agent rollback ollama-link <backup_id|latest>` pour restaurer l’état précédent du lien.
- fournir `agent ollama-models [status|rw|ro]` pour auditer/changer le mode de mount du store modèles, avec persistance dans `runtime.env`.

**Test** : `tests/C1_ollama_basic.sh`
- `agent ollama-models status` expose le mode de mount effectif + source runtime.
- cohérence entre mode configuré et mode réellement monté sur le conteneur `ollama`.

### C2 Smoke test génération
**Implémentation**
- script `deployments/ollama/smoke_generate.sh` (prompt court)
- prévoir modèle minimal de test (ou skip si aucun modèle présent)
- en VM dédiée à RAM contrainte : autoriser un petit modèle de validation (0.5B–3B) pour ce smoke test

**Test** : `tests/C2_ollama_generate.sh`
- POST `/api/generate` retourne 200 + payload non vide (avec timeout court)
- logs ollama présents

### C2b Modèle Ollama par défaut configurable + validation e2e “hello”
Suivi Beads : `dgx-spark-agentic-stack-ahh`

**Implémentation**
- introduire une variable runtime canonique `AGENTIC_DEFAULT_MODEL` (fallback `qwen3-coder:30b`) utilisée comme source de vérité pour:
  - preload Ollama (`OLLAMA_PRELOAD_GENERATE_MODEL`),
  - onboarding (`agent onboard --default-model`),
  - bootstrap OpenHands (`LLM_MODEL` par défaut).
- ajouter `AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW` (onboarding + runtime) et propager vers `OLLAMA_CONTEXT_LENGTH`.
- conserver la compatibilité avec les variables existantes (`OLLAMA_PRELOAD_GENERATE_MODEL`, `LLM_MODEL`) sans régression.
- exposer la valeur effective dans `agent profile` et la persister dans `${AGENTIC_ROOT}/deployments/runtime.env`.

**Test** : `tests/L5_default_model_e2e.sh`
- vérifie que le modèle par défaut est présent dans `ollama /api/tags`.
- exécute un appel `hello` direct sur Ollama (`/api/generate`) et valide une réponse non vide.
- exécute le même appel via `ollama-gate`.
- exécute le même appel depuis chaque agent (`claude`, `codex`, `opencode`, `vibestral`) via `ollama-gate`.
- exécute le même appel depuis `openwebui` et `openhands` via `ollama-gate`.

### C3 Backend alternatif : TRT-LLM (NVFP4) derrière le gate
**Implémentation**
- ajouter un service `trtllm` dédié dans un compose séparé (ex: `compose.trt.yml`) activé via profile (ex: `trt`), sans exposition host.
- bind réseau interne uniquement (pas de `ports:`), accès exclusivement depuis `ollama-gate`.
- stockage dédié (ex: `${AGENTIC_ROOT}/trtllm/{models,state,logs}`) pour moteurs/modèles NVFP4.
- healthcheck interne du runtime TRT-LLM.
- `agent onboard` propose par défaut `TRTLLM_MODELS=https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4`, et le fallback Compose/runtime reste aligné sur cette valeur.
- le conteneur `trtllm` embarque maintenant l'image NVIDIA `nvcr.io/nvidia/tensorrt-llm/release:1.3.0rc5`, lance `trtllm-serve serve` en backend natif quand `huggingface.token` est present, et garde un mode `mock` deterministe sans token.
- le mode standard `TRTLLM_NATIVE_MODEL_POLICY=auto` conserve le comportement générique, y compris la canonicalisation FP8 du slug Nemotron NVFP4 quand le backend natif sert directement un handle HF.
- le mode `TRTLLM_NATIVE_MODEL_POLICY=strict-nvfp4-local-only` impose au contraire un runtime NVFP4 préparé localement (`TRTLLM_NVFP4_LOCAL_MODEL_DIR`, défaut `/models/super_fp4`), sans fallback silencieux vers HF/FP8.
- documenter les prérequis GPU/moteurs NVFP4 et la procédure de chargement des modèles.

**Test** : `tests/C3_trtllm_basic.sh`
- `trtllm` est `healthy` lorsqu’activé.
- aucun port `trtllm` n’est publié sur l’hôte.
- accès direct externe refusé, accès interne depuis `ollama-gate` seulement.
- au premier boot natif, `/healthz` peut rester en `status=starting` pendant le téléchargement/chargement initial du modèle avant le premier `hello`.
 
---

## D — Point de contrôle LLM : `ollama-gate` (queue/priorités/sticky + logs/metrics)

### D1 Déployer `ollama-gate` devant Ollama
**Implémentation**
- ajouter service `ollama-gate` dans `compose.core.yml` (interne)
- endpoints :
  - compat OpenAI `/v1/*`
  - inclure explicitement `POST /v1/embeddings` (compat OpenAI) pour les flux RAG
  - `/metrics`
- ajouter un routage multi-backend dans `ollama-gate` :
  - backend par défaut = `ollama`;
  - backend alternatif = `trtllm` pour modèles NVFP4 (règles explicites par nom/pattern de modèle);
  - routage décidé par politique versionnée (ex: `${AGENTIC_ROOT}/gate/config/model_routes.yml`).
- persistance : `/srv/agentic/gate/{state,logs}/`
- config : concurrence=1, queue activée, sticky session via header `X-Agent-Session`

**Test** : `tests/D1_gate_up_metrics.sh`
- `curl -fsS http://ollama-gate:<port>/metrics | grep -q queue_depth` OK
- `/v1/models` répond
- `POST /v1/embeddings` répond (200 ou erreur modèle explicite, mais pas 404)

### D2 Discipline de concurrence + queue/deny explicite
**Implémentation**
- implémenter comportement “1 actif, le reste queued/denied avec raison”
- logs gate JSON (au minimum : ts, session, project, decision, latency, model_requested, model_served)

**Test** : `tests/D2_gate_concurrency.sh`
- lancer 2 requêtes longues en parallèle :
  - 1 passe, 1 queued/denied (statut vérifié)
- logs contiennent les champs attendus

### D3 Sticky model par session + switch contrôlé
**Implémentation**
- “sticky” : session -> modèle stable sur N requêtes
- endpoint admin interne (option) pour switch explicite

**Test** : `tests/D3_gate_sticky.sh`
- 3 requêtes même session → `model_served` identique
- tentative de changer modèle “à la volée” sans switch → refus/ignorée
- switch explicite → OK + log `model_switch:true`

### D4 Routage backend par modèle (Ollama vs TRT-LLM)
**Implémentation**
- exposer dans les logs gate le backend résolu (`backend=ollama|trtllm`) pour audit.
- forcer les modèles NVFP4 vers `trtllm` via la table de routage.
- conserver l’API client inchangée: les clients appellent toujours `ollama-gate` uniquement.

**Test** : `tests/D4_gate_backend_routing.sh`
- requête avec modèle standard -> backend `ollama` (preuve logs/headers gate).
- requête avec modèle NVFP4 -> backend `trtllm` (preuve logs/headers gate).
- si `trtllm` indisponible pour un modèle NVFP4 routé: erreur explicite et actionnable (pas de fallback silencieux non maîtrisé).

### D5 Backends LLM externes via `ollama-gate` (OpenAI/OpenRouter)
**Implémentation**
- ajouter un routage provider externe (au minimum `openai`, `openrouter`) dans `ollama-gate`, piloté par config versionnée `${AGENTIC_ROOT}/gate/config/model_routes.yml`.
- garder l’API client inchangée (`/v1/*`) : les agents/UIs appellent toujours uniquement `ollama-gate`.
- stocker les credentials providers hors git, fichiers root-only (ex: `${AGENTIC_ROOT}/secrets/runtime/openai.api_key`, `${AGENTIC_ROOT}/secrets/runtime/openrouter.api_key`).
- egress minimal : allowlist explicite des endpoints providers activés (pas d’ouverture générale).
- journaux gate enrichis : `backend`, `provider`, `model_requested`, `model_served`, sans fuite de secrets/tokens.

**Test** : `tests/D5_gate_external_providers.sh`
- modèle routé `openai` -> appel sortant via proxy vers endpoint OpenAI autorisé, réponse exploitable.
- modèle routé `openrouter` -> appel sortant via proxy vers endpoint OpenRouter autorisé, réponse exploitable.
- aucun secret provider dans logs gate/proxy.
- sans clé API valide : erreur explicite/actionnable (pas de fallback implicite non maîtrisé).

### D6 Mode “ressources locales” + quotas de tokens des appels externes
**Implémentation**
- ajouter un mode opératoire explicite : `agent llm mode <local|hybrid|remote>`.
- `local` : backends locaux seulement (Ollama/TRT-LLM), appels externes refusés.
- `hybrid` : local prioritaire + externe selon routage/politiques.
- `remote` : providers externes autorisés ; possibilité d’arrêter `ollama` et/ou `trtllm` pour libérer GPU/RAM tout en gardant les agents opérationnels via `ollama-gate`.
- implémenter des quotas de tokens/cout côté gate pour les providers externes :
  - budget journalier/mensuel par provider (et optionnellement par outil/projet) ;
  - compteurs persistants `${AGENTIC_ROOT}/gate/state/quotas.*` ;
  - refus explicite quand quota dépassé (erreur dédiée + logs d’audit).
- exposer métriques de coût/usage (`external_tokens_total`, `external_requests_total`, `external_quota_remaining`, etc.) pour alerting.

**Test** : `tests/D6_gate_quota_and_local_pause.sh`
- en mode `remote`, après arrêt `ollama`/`trtllm`, une requête agent passe encore via provider externe.
- en mode `local`, appel d’un modèle externe est refusé explicitement.
- dépassement quota simulé -> requêtes externes refusées, agents non plantés, logs/metrics cohérents.

### D7 MCP local pour visibilité runtime (modèle actif + tokens restants)
**Implémentation**
- ajouter un MCP local (service interne, sans exposition host) consommable par les agents locaux.
- exposer au minimum des outils MCP:
  - `gate.current_model` : retourne le modèle effectivement servi derrière `ollama-gate` (backend/provider/model_served), avec contexte session/projet.
  - `gate.quota_remaining` : retourne le quota/tokens restants pour les appels externes (global + par provider, et optionnellement par outil/projet).
  - `gate.switch_model` : demande un changement explicite de modèle pour une session (appel contrôlé vers `ollama-gate` `/admin/sessions/{session_id}/switch`), avec validation du modèle cible et traçabilité d’audit.
- source de vérité: état/métriques du gate (`${AGENTIC_ROOT}/gate/state/*` + endpoints internes) ; aucun secret provider ne doit être renvoyé.
- intégrer l’endpoint MCP local dans l’environnement des conteneurs agents (variables runtime dédiées), en gardant l’isolation réseau actuelle.
- hardening: auth locale minimale (token runtime local), rate limiting, logs d’audit.

**Test** : `tests/D7_local_mcp_gate_visibility.sh`
- depuis un conteneur agent, appel MCP `gate.current_model` -> réponse non vide avec backend/provider/model_served cohérents.
- depuis un conteneur agent, appel MCP `gate.quota_remaining` -> réponse avec compteurs restants cohérents.
- depuis un conteneur agent, appel MCP `gate.switch_model` (session existante) -> modèle sticky mis à jour et visible via `gate.current_model`; trace `model_switch:true` côté logs gate.
- en mode `remote` avec `ollama`/`trtllm` arrêtés, le MCP continue de refléter correctement le provider externe actif.
- accès non autorisé ou hors réseau interne -> refus explicite.

### D8 Compatibilité protocolaire multi-clients (`/v1/responses`, `/v1/messages`)
**Implémentation**
- exposer des endpoints de compatibilité OpenAI/Anthropic au niveau `ollama-gate` :
  - `POST /v1/responses` + alias `POST /responses` ;
  - `POST /v1/messages` + alias `POST /messages`.
- conserver une API client stable côté agents/UIs sans bypass direct vers les providers.
- supporter le streaming SSE sur `messages` (événements compatibles clients Anthropic).
- conserver la cohérence sticky/session du routage modèle pendant ces appels.

**Test** : `tests/D8_gate_protocol_compat.sh`
- `/v1/responses` et `/responses` retournent `200` + payload compatible.
- `/v1/messages` et `/messages` retournent `200` + payload compatible.
- stream `/v1/messages` expose les événements attendus (`content_block_delta`, `message_stop`).

### D9 Contrat `/v1/models` enrichi (metadata interop)
**Implémentation**
- enrichir la réponse `GET /v1/models` de `ollama-gate` avec des champs `metadata` non sensibles dérivés des catalogues backend (ex: Ollama `/api/tags`) tout en conservant les champs de base OpenAI-compatibles (`id`, `object`, `owned_by`).
- garantir une dégradation sûre: absence de metadata détaillée ne doit pas casser le endpoint.

**Test** : `tests/D9_gate_models_metadata.sh`
- `/v1/models` retourne `200` avec `object=list` et une liste non vide.
- chaque entrée conserve les champs de base compatibles (`id/object/owned_by`).
- au moins un modèle expose `metadata` avec provenance `ollama:/api/tags`.
- pour un modèle commun `/v1/models` <-> `/api/tags`, les champs enrichis clés (digest/size/family quand présents) sont cohérents.

---
 
## E — Agents CLI persistants : image `agent-cli-base` + tmux + workspaces

### E1 Construire `agent-cli-base`
**Implémentation**
- `deployments/images/agent-cli-base/Dockerfile`
  - base NVIDIA CUDA **devel** compatible DGX Spark (ARM64), version explicitement épinglée
  - socle CLI/runtime : bash, tmux, git, git-lfs, curl, ca-certificates, openssh-client, rsync
  - socle dev général : build-essential, cmake, ninja-build, pkg-config, python3+venv+pip, nodejs+npm, golang-go, rustc+cargo
  - outillage productivité/qualité : ripgrep, fd-find, jq, shellcheck, shfmt, direnv
  - socle C/C++ pro : gdb, gdbserver, valgrind, clang, clangd, lld, lldb, clang-format, clang-tidy, cppcheck, ccache, bear, meson, autoconf, automake, libtool
  - dépendances build natives communes : libc6-dev, libssl-dev, zlib1g-dev, libffi-dev, libbz2-dev, libreadline-dev, libsqlite3-dev
  - installer les CLIs agents officiels dans l'image commune (codex, claude code, opencode, vibe, openhands CLI, openclaw CLI) avec traçabilité de l'état d'installation (`/etc/agentic/*-real-path`) et wrappers de fallback explicites en cas d'échec egress
  - conserver user non-root + entrypoint tmux compatible
- pas de docker.sock, pas de privilèges

**Test** : `tests/E1_image_build.sh`
- `docker image inspect agent-cli-base:<tag>` OK
- `.Config.User` non-root
- `docker run --rm ... sh -lc 'command -v gcc g++ cmake ninja clang python3 pip node npm go rustc cargo nvcc'` OK
- `docker run --rm ... sh -lc 'command -v codex claude opencode vibe openhands openclaw'` OK
- smoke C/C++ : compilation simple (`gcc` + `g++`) OK
- smoke CUDA : `nvcc --version` OK (et test compile minimal CUDA si GPU/toolkit dispo)
- invariants sécurité conservés (`read_only`, `cap_drop=ALL`, `no-new-privileges`, pas de `docker.sock`)

### E1b Image de base commune customisable (Dockerfile override)
**Implémentation**
- permettre de surcharger le Dockerfile de base des agents (`agentic-claude`, `agentic-codex`, `agentic-opencode`, `agentic-vibestral`) via variables runtime (ex: `AGENTIC_AGENT_BASE_DOCKERFILE`, `AGENTIC_AGENT_BASE_BUILD_CONTEXT`).
- conserver un fallback sûr par défaut sur `deployments/images/agent-cli-base/Dockerfile` si aucun override n’est fourni.
- option de tagging explicite de l’image commune custom (ex: `AGENTIC_AGENT_BASE_IMAGE=agentic/agent-cli-base:custom`) pour traçabilité des releases.
- documenter clairement le contrat minimal du Dockerfile custom (user non-root, entrypoint compatible, outils de base requis).
- documenter dans un **nouveau runbook débutant** (`docs/runbooks/`) l’environnement de travail des agents (image de base, volumes, contraintes sécurité) et la procédure de personnalisation de l’image (variables `AGENTIC_AGENT_BASE_*`, exemple socle dev pro avec CUDA, rollback).
- le mécanisme custom ne doit pas casser le durcissement conteneur existant (`read_only`, `cap_drop=ALL`, `no-new-privileges`, pas de `docker.sock`).

**Test** : `tests/E1b_agent_base_image_override.sh`
- sans override: build/déploiement utilisent bien le Dockerfile par défaut.
- avec override: build utilise le Dockerfile custom fourni et l’image/tag attendu.
- les quatre services agents démarrent avec l’image commune custom.
- le nouveau runbook débutant existe et est référencé depuis la documentation d’introduction/runbooks.
- les invariants sécurité des agents restent inchangés.

### E2 Déployer `agentic-claude`, `agentic-codex`, `agentic-opencode`, `agentic-vibestral`
**Implémentation**
- `deployments/compose/compose.agents.yml`
- volumes par outil :
  - `${AGENTIC_ROOT}/<tool>/{state,logs}`
  - `${AGENTIC_AGENT_WORKSPACES_ROOT}/<tool>/workspaces` (fallback `${AGENTIC_ROOT}/<tool>/workspaces`)
- env :
  - `OLLAMA_BASE_URL=http://ollama-gate:<port>`
  - `HTTP(S)_PROXY=http://egress-proxy:3128`
  - `NO_PROXY=ollama-gate,unbound,egress-proxy,localhost,127.0.0.1`
- bootstrap first-run des agents : matérialiser un fichier persistant de defaults LLM dans `/srv/agentic/<tool>/state/bootstrap/ollama-gate-defaults.env` (ou `${AGENTIC_ROOT}` équivalent) pour forcer par défaut les endpoints `OLLAMA_BASE_URL` + `OPENAI_*_BASE_URL` vers `ollama-gate`, sans écraser un override explicite.
- sécurité conteneur :
  - `read_only: true`, `tmpfs: /tmp`
  - `cap_drop: [ALL]`
  - `security_opt: [no-new-privileges:true]`
- service dédié `agentic-vibestral` (même baseline sécurité que `codex-agent`) avec bootstrap Vibe CLI:
  1. `curl -LsSf https://mistral.ai/vibe/install.sh | bash`
  2. `vibe --setup`
- persister l’état Vibe dans `${AGENTIC_ROOT}/vibestral/state` (ou sous-répertoire explicite) pour éviter de relancer `--setup` à chaque redémarrage.
- expliciter pour chaque service son binaire CLI principal (`AGENT_PRIMARY_CLI`) et vérifier sa présence via `doctor` et tests E2.

**Test** : `tests/E2_agents_confinement.sh`
- `docker exec agentic-claude tmux has-session -t claude` OK (idem codex/opencode/vibestral)
- `docker exec agentic-claude sh -lc 'command -v claude'` OK (idem codex/opencode/vibe)
- `docker exec agentic-claude sh -lc 'test -f /state/bootstrap/ollama-gate-defaults.env'` OK (idem codex/opencode/vibestral) + variables résolues vers `http://ollama-gate:11435(/v1)`
- `docker inspect` prouve : non-root, readonly rootfs, cap_drop ALL, NNP
- egress : direct KO, via proxy conforme
- pour chaque agent (`claude`, `codex`, `opencode`, `vibestral`) :
  - `getent hosts github.com` renvoie une résolution DNS valide ;
  - `ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -T git@github.com` ne doit jamais échouer sur `Temporary failure in name resolution` (un refus d’authentification est acceptable).
- écritures : OK dans workspace/state/logs, KO ailleurs

---

## F — Commande unique `agent` + conformité + update/rollback par digest

### F1 Implémenter `agent` (opérations)
**Implémentation**
- compléter `/srv/agentic/bin/agent` :
  - `agent <tool>` : attache tmux, sélection projet (basename git ou dir)
  - `agent ls` : sessions actives + taille workspaces + modèle sticky (si dispo)
  - `agent logs <tool>`
  - `agent stop <tool>`
  - `agent up/down` multi-compose
- inclure `vibestral` comme tool de première classe (`agent vibestral <project>`).
- stocker config runtime dans `/srv/agentic/deployments/runtime.env` (non committé)

**Test** : `tests/F1_agent_cli.sh`
- `agent ls` fonctionne même si aucune session (retour propre)
- `agent claude` crée/attache une session tmux et workspace projet
- `agent vibestral` crée/attache une session tmux et workspace projet

### F2 Snapshot par digest + rollback strict
**Implémentation**
- `deployments/releases/snapshot.sh` :
  - capture digests (`docker compose images --digests` ou inspect)
  - copie compose effectifs + runtime.env (sans secrets)
  - enregistre `health_report.json`
- `deployments/releases/rollback.sh <id>` :
  - repin images par digest (ou tags->digests figés)
  - redeploy compose
- en `strict-prod`, associer le snapshot de release au dernier backup host-net disponible (référence `backup_id`) pour pouvoir restaurer aussi les changements imposés par `sudo`.
- journal : `deployments/changes.log`
- ajouter un bootstrap automatique de manifest release au premier `agent up ...` réussi si aucun `deployments/current/images.json` n’existe encore.

**Test** : `tests/F2_update_rollback.sh`
- `agent update` crée un snapshot complet (`deployments/releases/<ts>/…`)
- après un “changement” (pull latest), `agent rollback <ts>` restaure exactement les digests
- healthchecks redeviennent `healthy`
- complément de couverture : `tests/F5_auto_release_manifest.sh` valide la création auto d’un manifest release lors d’un `up`.

### F3 `agent doctor` (gating sécurité)
**Implémentation**
- `agent doctor` agrège :
  - `assert_no_public_bind`
  - DOCKER-USER présent + DROP final
  - proxy enforced (pas d’egress direct)
  - conformité conteneurs agents (non-root, NNP, cap_drop, ro)
  - health des conteneurs critiques
- comportement par profil :
  - `strict-prod` : tout écart structurant = `FAILED`;
  - `rootless-dev` : les checks host-root-only (DOCKER-USER, enforcement hôte impossible) passent en warning.

**Test** : `tests/F3_doctor.sh`
- en état nominal : doctor=PASSED
- si on force un bind `0.0.0.0` dans un compose de test : doctor=FAILED
- si DOCKER-USER absent : doctor=FAILED
- en `rootless-dev` : le test valide l’exécution de doctor sans exiger l’échec DOCKER-USER

### F3b Matrice de hardening Compose (contrôle statique global)
**Implémentation**
- ajouter un contrôle statique rendu `docker compose config` sur tous les services (core/agents/ui/obs/rag/optional) pour éviter les régressions de baseline sécurité.
- vérifier au minimum :
  - `cap_drop: [ALL]` ;
  - `security_opt` avec `no-new-privileges` cohérent avec le mode agent (`sudo-mode`) ;
  - `read_only: true` hors exceptions explicitement documentées ;
  - présence healthcheck ;
  - politique user non-root hors exceptions système explicites.

**Test** : `tests/F6_hardening_matrix.sh`
- échoue sur toute dérive de hardening dans la config Compose effective.

### F4 `agent forget` : reset ciblé des environnements persistants (mode “fresh install”)
**Implémentation**
- ajouter une commande destructive explicite :
  - `agent forget <target> --yes`
  - sans `--yes` : mode interactif obligatoire avec **deux confirmations successives** ;
  - chaque confirmation a `No` comme valeur par défaut (Entrée vide = `No`) ;
  - si l’une des deux confirmations n’est pas un `yes` explicite : refus + code non-zéro.
- objectifs :
  - supprimer toutes les données persistantes du domaine ciblé ;
  - recréer immédiatement l’arborescence/permissions/fichiers runtime comme à l’installation initiale (via `init_runtime.sh` concerné) ;
  - laisser les autres domaines intacts.
- cibles minimales à supporter :
  - `ollama`
  - `claude`
  - `codex`
  - `opencode`
  - `vibestral`
  - `comfyui`
  - `openclaw`
- cibles recommandées en plus (cohérence opératoire) :
  - `openhands`, `openwebui`, `qdrant`, `obs`, `all`.
- mapping attendu (exemples) :
  - `ollama` -> `${AGENTIC_ROOT}/ollama/**`
  - `claude` -> `${AGENTIC_ROOT}/claude/{state,logs,workspaces}/**`
  - `codex` -> `${AGENTIC_ROOT}/codex/{state,logs,workspaces}/**`
  - `opencode` -> `${AGENTIC_ROOT}/opencode/{state,logs,workspaces}/**`
  - `vibestral` -> `${AGENTIC_ROOT}/vibestral/{state,logs,workspaces}/**`
  - `comfyui` -> `${AGENTIC_ROOT}/comfyui/{models,input,output,user}/**`
  - `openclaw` -> `${AGENTIC_ROOT}/optional/openclaw/{config,state,logs}/**`
- orchestration de sécurité :
  - arrêter les services dépendants avant purge (`agent down` ciblé) ;
  - purge atomique par cible ;
  - ré-init runtime via scripts existants (`deployments/*/init_runtime.sh`) ;
  - journaliser l’action dans `${AGENTIC_ROOT}/deployments/changes.log` (acteur, UTC, cible, résultat).
- sauvegarde avant destruction :
  - créer un backup daté dans `${AGENTIC_ROOT}/deployments/forget-backups/<ts>-<target>.tar.gz` ;
  - option `--no-backup` possible mais non défaut.
- profils :
  - `strict-prod` : commande exécutable avec privilèges adaptés ;
  - `rootless-dev` : comportement équivalent sans exiger root, sauf chemins non accessibles (erreur explicite).

**Test** : `tests/F4_forget_command.sh`
  - pour chaque cible minimale (`ollama`, `claude`, `codex`, `opencode`, `vibestral`, `comfyui`, `openclaw`) :
  - créer un marqueur fichier persistant ;
  - exécuter `agent forget <target>` sans `--yes` puis Entrée vide à l’un des prompts -> refus attendu ;
  - exécuter `agent forget <target>` sans `--yes` et répondre `yes` aux deux prompts -> succès ;
  - exécuter `agent forget <target> --yes` -> succès ;
  - vérifier :
    - marqueur supprimé ;
    - arborescence runtime recréée ;
    - permissions minimales conformes ;
    - entrée `changes.log` présente ;
    - backup créé (sauf `--no-backup`).
- test d’isolation :
  - un `forget codex` ne supprime pas `claude/opencode`.
- test idempotence :
  - relancer `agent forget <target> --yes` sur cible déjà vide -> succès + état cohérent.

### F5 Pilotage ressources ciblé (stop/start services et conteneurs)
**Implémentation**
- ajouter des commandes de contrôle fin pour libérer/reprendre des ressources sans arrêter toute la stack :
  - `agent stop service <service...>`
  - `agent start service <service...>`
  - `agent stop container <container...>`
  - `agent start container <container...>`
- garde-fou : `stop/start container` doit refuser les conteneurs hors `com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}`.

**Test** : `tests/L1_stop_resources.sh`
- démarre une stack minimale (`optional-sentinel`) en projet isolé ;
- valide `stop/start service` ;
- valide `stop/start container` ;
- vérifie les transitions d’état (`running` <-> `exited`).

### F6 Orchestration stack stepwise (partielle ou complète)
**Implémentation**
- ajouter une commande unique d’orchestration sûre :
  - `agent stack stop <targets|all>` : arrêt stepwise en ordre sûr `optional -> rag -> obs -> ui -> agents -> core`
  - `agent stack start <targets|all>` : démarrage stepwise `core -> agents -> ui -> obs -> rag -> optional`
- fonctionnement sans intervention manuelle ; en cas d’échec d’une étape, retour non-zéro explicite.
- `all` doit représenter la baseline complète par défaut.

**Test** : `tests/L2_stack_stepwise.sh`
- valide le démarrage/arrêt stepwise via `agent stack start all` et `agent stack stop all` ;
- vérifie l’ordre effectif des étapes dans la sortie ;
- vérifie que les services ciblés sont bien up/down en fin d’opération.

### F7 Cleanup global “brand new” avec export/backup optionnel
Suivi Beads : `dgx-spark-agentic-stack-49e`

**Implémentation**
- ajouter une commande destructive explicite :
  - `agent cleanup [--yes] [--backup|--no-backup]`
  - `agent strict-prod cleanup [--yes] [--backup|--no-backup]`
  - `agent rootless-dev cleanup [--yes] [--backup|--no-backup]`
- comportement attendu :
  - exécuter la purge sur la racine runtime du profil actif :
    - `strict-prod` -> `/srv/agentic`
    - `rootless-dev` -> `${HOME}/.local/share/agentic` (ou override `AGENTIC_ROOT`) ;
  - demande interactive si un backup/export est souhaité (par défaut `yes`) ;
  - confirmation explicite obligatoire avant purge (ou `--yes`) ;
  - stop stepwise de la stack ;
  - export archive si demandé ;
  - purge complète de `${AGENTIC_ROOT}` pour revenir à un état “fresh/brand new” ;
  - suppression des images Docker locales de la stack ;
  - la suppression de fichiers/répertoires ne doit jamais suivre les liens symboliques (symlink-safe).

**Test** : `tests/L3_cleanup.sh`
- couvre le flux interactif (`backup + confirmation`) ;
- vérifie qu’une archive d’export est produite si demandée ;
- vérifie que `${AGENTIC_ROOT}` est vidé et que les services ciblés sont arrêtés ;
- vérifie que la commande profilée (`agent rootless-dev cleanup`) fonctionne ;
- vérifie qu’un symlink sous `${AGENTIC_ROOT}` est supprimé sans supprimer sa cible ;
- vérifie que les images Docker locales de la stack sont supprimées.

### F8 Backup incrémental “Time Machine” (persistant + config non-secrète)
**Implémentation**
- ajouter une commande dédiée :
  - `agent backup run` : snapshot incrémental horodaté ;
  - `agent backup list` : liste snapshots + taille + date + policy retention ;
  - `agent backup restore <snapshot_id>` : restauration déterministe d’un snapshot (opt-in destructif).
- couvrir les dossiers persistants `${AGENTIC_ROOT}` (états, logs, workspaces, releases), plus une copie de configuration système utile à l’exploitation (ex: règles réseau/compose effectif), **sans secrets**.
- exclure explicitement :
  - `${AGENTIC_ROOT}/secrets/**`,
  - clés/tokens/certs privés,
  - toute variable/fichier marqué secret.
- stratégie incrémentale “time machine” :
  - snapshots fréquents, déduplication/blocs ou hardlinks selon outil choisi ;
  - politique de rétention configurable (ex: hourly/daily/weekly).
- journaliser run/restore dans `${AGENTIC_ROOT}/deployments/changes.log` avec acteur, UTC, snapshot_id, résultat.

**Test** : `tests/F8_backup_incremental.sh`
- deux runs successifs sans changement -> second snapshot quasi nul (incrémental).
- après modification ciblée d’un dossier persistant -> snapshot suivant contient uniquement le delta attendu.
- `restore <snapshot_id>` restaure les fichiers persistants ciblés.
- vérification stricte : aucun fichier secret inclus dans snapshot/manifest.

### F9 Rollback hermétique depuis artefacts snapshot
Suivi Beads : `dgx-spark-agentic-stack-ywl`

**Implémentation**
- renforcer le rollback pour qu’il soit déterministe à partir des artefacts release uniquement :
  - source de vérité = `${AGENTIC_ROOT}/deployments/releases/<id>/{compose.effective.yml,images.json,...}` ;
  - éviter la dépendance aux fichiers Compose du working tree courant.
- conserver un mode de compatibilité explicite pour anciennes releases si nécessaire (fallback documenté).

**Test** : `tests/F9_rollback_hermetic_from_snapshot.sh`
- créer une release via `agent update` ;
- modifier ensuite un compose local (drift contrôlé) ;
- exécuter `agent rollback all <release_id>` ;
- vérifier que le rollback restaure l’état de la release (images/services/health) malgré le drift du repo.

### F10 Intégrité des artefacts de release + anti-fuite secrets
Suivi Beads : `dgx-spark-agentic-stack-7eo`

**Implémentation**
- formaliser le contrat minimal des artefacts de release :
  - `release.meta`, `images.json`, `health_report.json`, `compose.effective.yml`, `compose.files`, `runtime.env` (redacté).
- ajouter un contrôle anti-fuite de secrets dans les artefacts exportés (mots-clés + patterns usuels).

**Test** : `tests/F10_release_artifact_integrity.sh`
- vérifie la présence/cohérence des fichiers obligatoires d’une release.
- vérifie que `runtime.env` exporté n’expose pas de clés/valeurs sensibles.
- vérifie que `images.json` contient les champs requis par service (image configurée/résolue, digest, état, santé).

### F11 Cohérence du schéma runtime env (anti-drift)
Suivi Beads : `dgx-spark-agentic-stack-3je`

**Implémentation**
- centraliser/normaliser la liste des clés runtime attendues pour réduire la dérive entre :
  - `scripts/lib/runtime.sh` (defaults/export),
  - `load_runtime_env` / `ensure_runtime_env`,
  - `agent profile`.
- rendre la dérive détectable en CI via test dédié.

**Test** : `tests/F11_runtime_env_schema_drift.sh`
- compare les clés exposées dans les différents points de vérité runtime.
- échoue si une clé est présente dans une couche mais absente/incohérente ailleurs.
- vérifie la stabilité minimale du contrat `agent profile` pour les clés critiques.

### F12 Contrat `agent doctor` par profil (strict-prod vs rootless-dev)
Suivi Beads : `dgx-spark-agentic-stack-eus`

**Implémentation**
- expliciter et figer le contrat attendu :
  - `strict-prod` : écarts structurants => échec non-zéro ;
  - `rootless-dev` : checks host-root-only => warning/skip, sans masquer les échecs runtime réels.
- couvrir les cas limites de flags `AGENTIC_SKIP_*` pour éviter les régressions de sévérité.

**Test** : `tests/F12_doctor_profile_contract.sh`
- valide que `doctor` échoue en `strict-prod` sur une dérive host-root structurante.
- valide que la même dérive est downgradée en warning/skip en `rootless-dev`.
- valide que les dérives runtime (ex: santé conteneur, bind public critique) restent bloquantes dans les deux profils.

---

## G — Observabilité : Prometheus + Grafana + Loki + DCGM exporter

### G0 Réparation ownership rootless + migration promtail (pré-vol obs)
**Implémentation**
- rendre `deployments/obs/init_runtime.sh` idempotent en mode `rootless-dev`, y compris après dérive d’ownership/permissions.
- corriger automatiquement ownership UID:GID runtime des dossiers `monitoring/*`.
- migrer la config promtail legacy (`/var/log/agentic-proxy/...`) vers le chemin runtime attendu (`/tmp/agentic-proxy/...`) quand nécessaire.

**Test** : `tests/G0_obs_rootless_ownership_repair.sh`
- vérifie réparation ownership/permissions + idempotence.
- vérifie migration de chemin promtail et suppression de l’ancien chemin legacy.

### G1 Déployer stack obs
**Implémentation**
- `deployments/compose/compose.obs.yml` :
  - prometheus, grafana, loki, promtail (ou vector), node_exporter, cadvisor, dcgm-exporter
- binds hôte : grafana/prometheus en `127.0.0.1` seulement
- persistance : `/srv/agentic/monitoring/…`

**Test** : `tests/G1_obs_up.sh`
- `curl -fsS http://127.0.0.1:<grafana>/login` OK (et pas sur 0.0.0.0)
- prometheus targets UP via API `/api/v1/targets`
- loki reçoit des logs (query retourne ≥1 entrée)
- métriques GPU (`dcgm_*`) présentes

### G2 Dashboard Grafana “first-run” pour activité agents/outils/réseau/modèles
**Implémentation**
- provisioning Grafana automatique au premier démarrage (`datasources` + `dashboard provider` + dashboard JSON) via `${AGENTIC_ROOT}/monitoring/config/grafana/...` ;
- dashboard par défaut “home” : **DGX Spark Agentic Activity Overview** ;
- panneaux couvrant au minimum :
  - appels modèles par agent/projet (`claude`, `codex`, `opencode`, `vibestral`, `openwebui`, `openhands`) ;
  - latence et tokens externes côté `ollama-gate` ;
  - appels outils via audit `gate-mcp` ;
  - activité réseau (requêtes egress + throughput par service).
- ingestion promtail étendue pour logs structurés `gate` + `gate-mcp` afin d’alimenter les panels sans configuration manuelle post-install.

**Test** : `tests/G2_obs_dashboard_provisioning.sh`
- artefacts de provisioning présents sous `${AGENTIC_ROOT}/monitoring/config/grafana/...` ;
- fichiers montés dans le conteneur Grafana ;
- datasources provisionnées (`Prometheus`, `Loki`) visibles via API Grafana ;
- dashboard `uid=dgx-spark-activity` présent via API Grafana.

---

## H — UIs web demandées : OpenWebUI + OpenHands (durci)

### H1 OpenWebUI (auth obligatoire, via gate)
**Implémentation**
- `deployments/compose/compose.ui.yml` : openwebui
- bind hôte : `127.0.0.1:8080`
- auth obligatoire (bootstrap admin)
- backend LLM = `ollama-gate`
- onboarding : ajouter un flag explicite (désactivé par défaut) pour autoriser le pull de modèles depuis OpenWebUI via l’API Ollama native, tout en conservant le chemin OpenAI-compatible via `ollama-gate` par défaut
- onboarding/allowlist par défaut : inclure `registry.ollama.ai` (nécessaire au téléchargement de modèles Ollama)
- persistance : `/srv/agentic/openwebui/`

**Test** : `tests/H1_openwebui.sh`
- port local-only
- accès sans auth refusé (code cohérent)
- une requête LLM depuis OpenWebUI apparaît dans logs gate (tag/header “client” si configuré)

### H2 OpenHands (pas de docker.sock par défaut)
**Implémentation**
- openhands bind `127.0.0.1:3000`
- persistance `/srv/agentic/openhands/`
- interdiction montage `/var/run/docker.sock`
- option : docker-socket-proxy filtrant (désactivé par défaut, activable étape K)

**Test** : `tests/H2_openhands.sh`
- port local-only
- `docker inspect` : aucun mount docker.sock
- OpenHands utilise gate (preuve logs gate)

---

## I — ComfyUI (GPU) : génération d’images sous contrôle

### I1 Déployer ComfyUI
**Implémentation**
- service comfyui dans `compose.ui.yml` (ou `compose.comfy.yml`)
- bind : `127.0.0.1:8188`
- volumes :
  - `/srv/agentic/comfyui/models`
  - `/srv/agentic/comfyui/input`, `/output`, `/user`
- profil GPU “lowprio” (au moins séparation logique)

**Test** : `tests/I1_comfyui.sh`
- UI répond
- exécuter un workflow “smoke” (API si dispo) produisant un fichier dans `output/`
- port local-only
- downloads éventuels passent par proxy (sinon bloqués)

---

## J — RAG hybride progressif : dense + lexical (skeleton J3/J4)

### J1 Déployer Qdrant interne
**Implémentation**
- `deployments/compose/compose.rag.yml` : qdrant
- **pas** de port host publié
- persistance : `/srv/agentic/rag/qdrant/`

**Test** : `tests/J1_qdrant.sh`
- aucun publish host sur 6333/6334
- health OK depuis toolbox interne

### J2 Ingestion reproductible + mini-corpus
**Implémentation**
- `/srv/agentic/rag/docs/` corpus test
- `/srv/agentic/rag/scripts/ingest.sh` :
  - embeddings via `ollama-gate` (backend effectif selon routage : `ollama` ou `trtllm`)
  - index qdrant
- `/srv/agentic/rag/scripts/query_smoke.sh`

**Test** : `tests/J2_rag_smoke.sh`
- ingestion : nb docs indexés == attendu
- query : retourne ≥N hits
- mode offline : si proxy coupé, RAG continue de fonctionner sur corpus local (sans fetch web)

### J3 Schéma canonique des chunks (dense + lexical)
**Implémentation**
- définir un schéma unique de document/chunk (JSON Schema) utilisé par ingestion/retrieval :
  - `doc_id`, `chunk_id`, `text`, `source_type`, `source_path`,
  - provenance code/pdf (`page` ou `file_path` + `start_line`/`end_line`),
  - versioning (`repo`, `branch`, `commit_sha`, `timestamp`, `version`),
  - métadonnées utiles (`section`, `title`, `authors`, `doi`, `language`).
- artefacts :
  - `deployments/rag/document.schema.json` (source contrôlée git),
  - `${AGENTIC_ROOT}/rag/config/document.schema.json` (runtime matérialisé).

**Test** : `tests/J3_rag_schema.sh`
- schéma JSON valide ;
- champs requis présents ;
- champs de provenance code/pdf présents ;
- enum `source_type` contient au minimum `pdf` et `code`.

### J4 Retrieval orchestrator hybride (full)
**Implémentation**
- étendre `compose/compose.rag.yml` avec services internes (sans exposition host) :
  - `rag-retriever` (API orchestrateur dense+lexical+fusion),
  - `rag-worker` (worker async pour pipeline retrieval/indexation),
  - `opensearch` optionnel sous profile `rag-lexical` (BM25 lexical).
- comportement full attendu :
  - endpoint `rag-retriever` `/v1/retrieve` exécute réellement `dense` (`qdrant`) et `lexical` (`opensearch` si activé) ;
  - contrat de réponse conserve les sections `dense`, `lexical`, `fusion` avec résultats ;
  - fusion effective par défaut en `rrf` ;
  - audit minimal des requêtes retrieval et indexation.

**Test** : `tests/J4_rag_hybrid_skeleton.sh`
- `rag-retriever` et `rag-worker` démarrent et passent healthchecks ;
- aucun port host publié pour les services retrieval ;
- `/v1/retrieve` répond avec contrat full (`fusion.method=rrf`, `dense.backend=qdrant`, hits non vides après indexation) ;
- si profile `rag-lexical` activé : `opensearch` reste interne-only (pas de publish host).

---

## K — Modules optionnels à risque : OpenClaw / MCP Catalog / pi-mono / goose / Portainer / Git forge (activation conditionnelle)

Principe : **désactivé par défaut**. Un module n’est activé que si :
- besoin explicite + définition de succès
- il passe la même barre que le noyau (confinement, traçabilité, pas d’expo host, secrets propres)

### K0 Harness “optional gating”
**Implémentation**
- `deployments/compose/compose.optional.yml` (vide par défaut ou services commentés)
- `agent up optional` refuse si `agent doctor` n’est pas vert (garde-fou)
- en `rootless-dev` : ce scénario de refus peut être neutralisé si la non-conformité ne concerne que des contrôles host-root-only.

**Test** : `tests/K0_optional_gating.sh`
- `agent up optional` échoue si doctor rouge, passe si doctor vert

### K1 OpenClaw (si activé)
**Implémentation**
- auth token fort (secret runtime)
- DM policy allowlist
- sandbox activée
- **option sandbox séparée** : exécution des actions OpenClaw dans un nouveau conteneur dédié (ex: `optional-openclaw-sandbox`) distinct de `optional-openclaw`, sur réseau Docker interne uniquement, sans bind host direct
- canal interne OpenClaw -> sandbox explicite (API interne ou queue), avec timeouts et logs d’exécution corrélés (`request_id`)
- vérification de reachability sandbox côté agent OpenClaw (healthcheck interne + check applicatif de disponibilité avant exécution d’outil)
- ingress entrant contrôlé pour webhooks (loopback-only côté hôte, auth/signature obligatoire, pas d’ouverture publique)
- outils OpenClaw exécutables via sandbox dédié avec allowlist explicite des outils/commandes autorisés
- egress via proxy + DOCKER-USER
- logs d’audit centralisés

**Test** : `tests/K1_openclaw.sh`
- endpoint refuse sans token
- actions génèrent logs d’audit
- OpenClaw confirme que le sandbox dédié est joignable (health endpoint interne OK)
- webhook entrant signé atteint OpenClaw (cas nominal) et est rejeté si signature/token invalide
- au moins un outil allowlisté est exécutable via OpenClaw -> sandbox et produit une trace d’audit
- aucune ouverture `0.0.0.0`
- aucun egress direct possible

### K2 MCP Catalog (si activé)
**Implémentation**
- allowlist stricte des tools
- secrets minimaux dans `/srv/agentic/secrets/runtime`
- pas d’expo host, logs fins

**Test** : `tests/K2_mcp.sh`
- tool non allowlisté → refus
- secrets non présents dans workspaces
- logs centralisés

### K3 Portainer (si activé)
**Implémentation**
- bind local-only
- pas de docker.sock brut : docker-socket-proxy filtrant, ou alternative CLI
- justification d’activation dans `deployments/changes.log`

**Test** : `tests/K3_portainer.sh`
- port local-only
- pas de mount docker.sock direct
- si socket-proxy : seules APIs allowlistées répondent

### K4 pi-mono (si activé)
**Implémentation**
- profile Compose : `optional-pi-mono`.
- exécution via image `agent-cli-base` locale, persistance dédiée `${AGENTIC_ROOT}/optional/pi-mono/{state,logs,workspaces}`.
- baseline hardening identique aux agents CLI (non-root, read-only, cap_drop ALL, NNP).

**Test** : `tests/F6_hardening_matrix.sh`
- vérifie la baseline hardening de `optional-pi-mono` dans la config Compose rendue.

### K5 goose (si activé)
**Implémentation**
- profile Compose : `optional-goose`.
- service interne-only, persistance dédiée `${AGENTIC_ROOT}/optional/goose/{state,logs,workspaces}`.
- baseline hardening alignée optional (read-only, cap_drop ALL, NNP, pas de bind public).

**Test** : `tests/F6_hardening_matrix.sh`
- vérifie la baseline hardening de `optional-goose` dans la config Compose rendue.

### K6 Git forge partagé (si activé)
Suivi Beads : `dgx-spark-agentic-stack-zu7n`

**Implémentation**
- profile Compose : `optional-git-forge`.
- service recommandé : `optional-forgejo` (ou autre forge Gitea-compatible) avec UI/API HTTP bindées uniquement sur `127.0.0.1:${GIT_FORGE_HOST_PORT:-13010}` et reachability interne via le réseau Docker privé.
- persistance dédiée :
  - `${AGENTIC_ROOT}/optional/git/config`
  - `${AGENTIC_ROOT}/optional/git/state`
  - `${AGENTIC_ROOT}/optional/git/bootstrap`
- base de données et dépôts doivent survivre aux redémarrages ; `agent update` enregistre le digest image réellement déployé, la version de la forge et les artefacts utiles au rollback ; `agent rollback` doit pouvoir restaurer une release cohérente avec la base et les dépôts persistants.
- bootstrap initial idempotent d’un compte opérateur `system-manager` avec rôle System Manager / admin, accessible depuis l’hôte via l’UI loopback-only.
- bootstrap initial idempotent de comptes dédiés pour `openclaw`, `openhands`, `comfyui`, `claude`, `codex`, `opencode`, `vibestral`, `pi-mono`, `goose`.
- chaque compte agent reçoit des credentials stockés hors git (fichiers root-only ou secrets injectés) permettant `git clone`, `fetch`, `pull`, `push` contre la forge interne ; les chemins et la rotation de ces credentials doivent être documentés.
- chaque conteneur agent concerné doit aussi recevoir une préconfiguration Git stack-managed (identity + auth) pointant vers la forge interne, de façon à permettre un premier `git clone`/checkout direct dès la première session sans setup manuel dans le shell utilisateur.
- transport par défaut : HTTP interne sur le réseau Docker privé + fichiers mot de passe dédiés ; SSH côté forge désactivé par défaut sauf besoin explicite documenté.
- prévoir un bootstrap minimal d’organisation/projet partagé pour permettre à plusieurs agents de collaborer sur les mêmes dépôts sans dépendre d’un fournisseur externe.
- à la première initialisation complète de la stack avec `git-forge` actif, créer de façon idempotente un projet/dépôt partagé de référence pour le test d’intégration agentique (problème des 8 reines) :
  - le dépôt doit porter l’énoncé du problème, la structure Python cible, la commande de test et le contrat de vérification de sortie ;
  - les tests du dépôt doivent vérifier au minimum la correction fonctionnelle attendue et produire un résultat exploitable automatiquement par l’orchestrateur/doctor ;
  - la branche par défaut `main` doit être protégée contre les pushes directs des comptes agents ;
  - une branche dédiée par agent doit être créée ou réservée (`agent/codex`, `agent/openclaw`, `agent/claude`, `agent/opencode`, `agent/openhands`, `agent/pi-mono`, `agent/goose`, `agent/vibestral`) ;
  - le scénario E2E doit imposer à chaque agent de ne pousser que sur sa branche dédiée et le doctor doit signaler explicitement tout push agent sur `main` comme échec de conformité.
- onboarding explicite requis : `agent onboard` doit proposer l’activation de `git-forge`, écrire les variables non secrètes (`AGENTIC_OPTIONAL_MODULES`, `GIT_FORGE_HOST_PORT`, `GIT_FORGE_ADMIN_USER`, `GIT_FORGE_SHARED_NAMESPACE`, `GIT_FORGE_ENABLE_PUSH_CREATE`) dans le fichier env généré, créer/recueillir séparément les secrets runtime nécessaires, et annoncer que la configuration Git des agents sera préchargée pour un premier checkout direct.
- `agent doctor` vérifie, quand le profile est actif, le bind loopback-only, l’absence de `docker.sock`, la persistance DB/repos au bon endroit, la présence d’un healthcheck, l’existence du compte opérateur et la cohérence de la liste des comptes agents attendus.
- documentation opérateur obligatoire : bootstrap initial, création/rotation/révocation des comptes, création de dépôt, partage inter-agents, sauvegarde/restauration, conformité.

**Test** : `tests/K10_git_forge.sh`
- service `optional-forgejo` healthy ; UI répond sur `127.0.0.1` uniquement.
- aucun bind `0.0.0.0`, aucun mount `docker.sock`, baseline hardening conforme.
- volumes DB et dépôts pointent vers `${AGENTIC_ROOT}/optional/git/...`.
- compte `system-manager` existe avec rôle admin/manager.
- comptes `openclaw`, `openhands`, `comfyui`, `claude`, `codex`, `opencode`, `vibestral`, `pi-mono`, `goose` existent.
- le dépôt/projet partagé `eight-queens-agent-e2e` existe après première initialisation et contient bien l’énoncé, la commande de test et le contrat de vérification de sortie.
- `main` est protégée contre les pushes directs des comptes agents ; les branches `agent/<tool>` attendues existent ou sont réservées.
- depuis au moins deux conteneurs agents distincts : première session shell -> `git clone`/checkout d’un dépôt de la forge sans saisie de credential manuelle fonctionne ; puis `git commit`, `git push`, `git fetch`, `git pull` sur un même dépôt partagé fonctionnent.
- le test E2E de référence échoue explicitement si un agent pousse sur `main` au lieu de sa branche dédiée.
- backup/restore ou rollback restaure un dépôt test et la métadonnée DB correspondante.

---

## L — Exploitation transverse (ressources, cleanup, modèle par défaut)

Cette section regroupe des capacités déjà implémentées mais transverses aux sections C/F.

### L1 Stop/start ciblé services & conteneurs
**Implémentation**
- `agent stop service <service...>` / `agent start service <service...>`.
- `agent stop container <container...>` / `agent start container <container...>`.
- garde-fou : refus hors projet Compose actif.

**Test** : `tests/L1_stop_resources.sh`
- valide les transitions `running <-> exited` sur service et conteneur.

### L2 Orchestration stepwise de la stack
**Implémentation**
- `agent stack start <targets|all>` (`core -> agents -> ui -> obs -> rag -> optional`).
- `agent stack stop <targets|all>` (`optional -> rag -> obs -> ui -> agents -> core`).

**Test** : `tests/L2_stack_stepwise.sh`
- valide ordre effectif + état final des services.

### L3 Cleanup global profilé (brand new)
**Implémentation**
- `agent cleanup` avec variantes profilées (`agent strict-prod cleanup`, `agent rootless-dev cleanup`).
- purge symlink-safe + export optionnel + suppression images locales stack.

**Test** : `tests/L3_cleanup.sh`
- valide flow interactif, sécurité symlink et état final propre.

### L4 Fallback cleanup rootless en cas de permission denied
**Implémentation**
- en `rootless-dev`, si purge directe échoue sur arborescence runtime (permissions), basculer sur un helper Docker de nettoyage.
- conserver un log explicite du fallback et terminer sur un état runtime propre.

**Test** : `tests/L4_cleanup_permission_denied_fallback.sh`
- simule une arborescence non purgeable en direct et valide le fallback + résultat final.

### L5 Modèle par défaut e2e multi-clients
**Implémentation**
- propager `AGENTIC_DEFAULT_MODEL` de bout en bout (Ollama direct, gate, agents, UIs).
- garantir une réponse non vide sur scénario de smoke `hello`.
- vérifier la cohérence modèle/contexte/ressources locales dans `agent doctor`.

**Test** : `tests/L5_default_model_e2e.sh`
- valide le flux `hello` via Ollama, gate, agents et UIs.

### L7 Tool-calling FS ops sur 5 agents (modèle local par défaut)
Suivi Beads : `dgx-spark-agentic-stack-5bz`

**Implémentation**
- ajouter un test agentique qui valide, via `ollama-gate`, les opérations tool-calling `write_file`, `read_file`, `run_python`, `delete_file`.
- exécuter le scénario pour `agentic-claude`, `agentic-codex`, `agentic-opencode`, `agentic-vibestral` et `openhands`.

**Test** : `tests/L7_default_model_tool_call_fs_ops.sh`
- échoue si un des 5 services n’arrive pas à effectuer le workflow fichiers complet avec le modèle local par défaut.

---

## Validation complémentaire — VM dédiée `strict-prod` (prod-like)

Suivi Beads : `dgx-spark-agentic-stack-9kz`

### V1 Campagne de validation complète en VM
**Implémentation**
- provisionner une VM Linux dédiée (Ubuntu LTS recommandé) avec privilèges root ;
- ajouter des commandes opérateur dédiées :
  - `agent vm create --name <vm-name> --cpus <n> --memory <size> --disk <size> [--require-gpu]`
  - `agent vm test --name <vm-name> [--test-selectors <csv|all>] [--allow-no-gpu|--require-gpu] [--skip-d5-tests]`
  - `agent vm cleanup --name <vm-name>`
  - comportement attendu : create/test/cleanup orchestrés sans toucher d’autres VMs ;
- exécuter strictement le profil :
  - `export AGENTIC_PROFILE=strict-prod`
  - `sudo ./deployments/bootstrap/init_fs.sh`
  - `sudo ./agent up core`
  - `sudo ./agent up agents,ui,obs,rag`
  - `sudo ./agent doctor`
  - `sudo ./agent update`
  - `sudo ./agent rollback all <release_id>`
  - `sudo ./agent test all`
- capturer les preuves dans `${AGENTIC_ROOT}/deployments/validation/vm-strict-prod/<ts>/` :
  - sortie `agent doctor`,
  - rapport des tests,
  - identifiants de release update/rollback,
  - état final `agent ps`.
- si la VM n’a pas de GPU passthrough : documenter explicitement les tests GPU en `skip/blocked` avec justification (pas de contournement sécurité).

**Test** : `tests/V1_vm_strict_prod_validation.sh`
- contrat dry-run create : `tests/00_vm_create_dry_run.sh`
- contrat dry-run cleanup : `tests/00_vm_cleanup_dry_run.sh`
- vérifie que le script de campagne retourne `0` quand la VM satisfait les prérequis ;
- vérifie la présence des artefacts de preuve ;
- échoue si `doctor` strict est non vert hors exceptions explicitement marquées ;
- échoue si update/rollback ne laissent pas la stack dans un état `healthy`.

---

## Backlog transverse — limites, hardening uniforme, doctor

Suivi Beads :
- `dgx-spark-agentic-stack-blw` — onboarding/runtime : customisation des limites CPU/RAM pour l’ensemble des services conteneurisés.
- `dgx-spark-agentic-stack-vgl` — onboarding : ajouter une question explicite `AGENTIC_LIMIT_OLLAMA_MEM` (et son flag non-interactif) pour éviter un héritage implicite trop restrictif depuis `AGENTIC_LIMIT_CORE_MEM`.
- `dgx-spark-agentic-stack-2oj` — étude + remédiation du hardening non uniforme (services encore root par défaut en `strict-prod`, healthchecks manquants sur services longue durée).
- `dgx-spark-agentic-stack-dvo` — extension de `agent doctor` pour appliquer des contrôles de sécurité profonds de manière uniforme sur tous les services gérés.
- `dgx-spark-agentic-stack-0li` — accès `sudo` pour les agents dans leur propre conteneur uniquement (sans élévation hôte, sans `docker.sock`), avec cadrage conformité/sécurité.
- `dgx-spark-agentic-stack-kvs` — onboarding premier démarrage complet (interface type CMake/ccmake) incluant admin/password, allowances réseau et secrets sans étape manuelle cachée.
- `dgx-spark-agentic-stack-581` — onboarding OpenWebUI : flag optionnel “allow model pull” + extension allowlist par défaut `registry.ollama.ai`.
- `dgx-spark-agentic-stack-0p4` — `agent ollama-preload` doit préserver le mode de mount initial (`rw`/`ro`) pour éviter les recreates inutiles et les changements d’état inattendus.
- `dgx-spark-agentic-stack-2ld` — enrichir `/v1/models` dans `ollama-gate` avec des métadonnées de modèles non sensibles (issues des backends, notamment Ollama `/api/tags`) pour améliorer l’interopérabilité client.
- `dgx-spark-agentic-stack-41m` — introduire `AGENTIC_AGENT_WORKSPACES_ROOT` (onboarding/runtime + defaults `rootless-dev`) pour isoler proprement les workspaces agents.
- `dgx-spark-agentic-stack-zs0` — onboarding/runtime : ajouter des chemins persistants `/workspace` dédiés par conteneur (`AGENTIC_{CLAUDE,CODEX,OPENCODE,VIBESTRAL,OPENHANDS}_WORKSPACES_DIR`) pour montage explicite service par service.

Objectif :
- traiter ces sujets comme un chantier transverse post-chemin-critique, sans régression sur les invariants CDC (bind loopback, pas de `docker.sock`, traçabilité/rollback stricts).
- définir une politique explicite d’élévation intra-conteneur pour les agents (`sudo` local au conteneur uniquement), documenter l’écart éventuel avec le hardening (`no-new-privileges`, `cap_drop`) et ajouter les contrôles associés dans `agent doctor`.

---

## Définition “terminé” (objectif final)
La stack est “opérable” quand :
- `agent doctor` est vert de façon stable
- egress libre impossible (proxy + DOCKER-USER prouvés)
- Ollama local-only fonctionne et est consommé via `ollama-gate` (queue+sticky+metrics)
- si activé, backend TRT-LLM (modèles NVFP4) est routé via `ollama-gate` vers le conteneur `trtllm` sans exposition host
- agents CLI persistants (tmux) confinés (non-root, NNP, cap_drop ALL, rootfs ro), incluant `agentic-vibestral` avec Vibe CLI initialisé.
- UIs demandées (OpenWebUI, OpenHands, ComfyUI) bind local + auth, et ne cassent pas la posture
- observabilité exploitable (CPU/RAM/disque/GPU, logs, erreurs proxy, drops DOCKER-USER)
- update/rollback stricts par digest reproductibles
- rollback hôte disponible pour les modifications nécessitant `sudo` (au minimum DOCKER-USER), testé et journalisé
- routage LLM externe via `ollama-gate` possible (OpenAI/OpenRouter) avec API client stable `/v1/*`
- mode `agent llm mode <local|hybrid|remote>` permet d’arrêter les backends locaux (`ollama`/`trtllm`) sans interrompre l’usage agentique en mode `remote`
- quotas tokens/coût des appels externes actifs et auditables (blocage explicite au dépassement)
- les agents locaux peuvent interroger un MCP local pour connaître le modèle effectif servi par `ollama-gate` et le quota/tokens externes restants
- backup incrémental “time machine” des dossiers persistants + config non-secrète, avec restauration testée

Critères de clôture par profil :
- `strict-prod` : tous les points ci-dessus sont obligatoires et bloquants.
- `rootless-dev` : mode accepté pour développement local, avec traçabilité claire des écarts non validables sans root.
- `strict-prod` sur VM dédiée : accepté pour validation “prod-like” du pipeline A→L avec petit modèle Ollama ; tests de charge/modèles lourds restent hors périmètre de cette VM contrainte.

---

## Ordre d’exécution imposé (chemin critique)
A → B → C → D → E → F → G → H → I → J → K → L

Validation complémentaire recommandée après chemin critique :
- V1 (VM dédiée `strict-prod` prod-like)

Stop condition générale : si une étape exige des privilèges élevés non compensés (root + caps + accès host), elle reste désactivée, et on documente le refus dans `deployments/changes.log`.

