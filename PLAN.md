# DGX Spark Agentic Platform v2 — Plan stratégique de réécriture et de migration

## 0. Statut et gouvernance

Ce document est la source de vérité du projet v2. La v1 reste la référence fonctionnelle jusqu’à validation explicite de chaque domaine migré.

Référence v1 :

- branche : `archive/pre-v2-rewrite-2026-06-25` ;
- commit : `f76778e342d43fdafaa17e05ad887f6e9853aa7d`.

La pull request reste en brouillon tant que les décisions bloquantes ne sont pas closes.

### 0.1 Statuts de décision

- **DÉCISION** : choix interne sous notre contrôle ;
- **CIBLE** : direction retenue, à valider avant généralisation ;
- **HYPOTHÈSE** : capacité plausible mais non démontrée ;
- **BLOQUANT** : preuve nécessaire avant la phase dépendante.

Une hypothèse ne devient jamais implicitement une dépendance de production.

### 0.2 Règles

- Beads reste l’unique backlog opérationnel ;
- chaque capacité v1 reçoit `conserver`, `remplacer`, `reconstruire` ou `retirer` ;
- `retirer` exige une décision humaine documentée ;
- toute dépendance externe est épinglée par version ou digest et entourée d’un adapter ;
- aucune bascule ne partage en écriture un état mutable entre v1 et v2 ;
- toute migration possède dry-run, rapport, validation et rollback ;
- sauvegarde et restauration sont testées avant la migration ;
- toute affirmation sur une capacité amont est reliée à une documentation officielle, une version et un test reproductible.

## 1. Contrat produit

La v2 doit être administrable sur une seule DGX Spark par une petite équipe, sans constellation inutile de microservices et sans exiger des utilisateurs qu’ils comprennent Docker, OpenShell ou les ports internes.

### 1.1 Expérience attendue

- l’utilisateur choisit d’abord un agent, puis éventuellement un projet ;
- un projet est un contexte de travail, pas le point d’entrée principal ;
- chaque agent ou application possède une surface explicite : CLI, portail, interface native, ou plusieurs ;
- une déconnexion SSH ne détruit pas une session reprenable ;
- les interfaces officielles utiles sont préservées : terminal, web, Desktop, IDE, ACP ou messagerie ;
- les permissions et l’état restent cohérents entre les surfaces ;
- la plateforme reste utilisable hors Internet pour les capacités locales ;
- aucun téléchargement lourd, update, publication ou effacement n’est silencieux ;
- les erreurs sont actionnables et désignent le composant réellement en cause.

### 1.2 Principes d’implémentation

- préserver les capacités, pas nécessairement les implémentations v1 ;
- préférer un composant amont mature si son contrat est réellement couvert ;
- commencer par un monolithe modulaire de contrôle ;
- conserver agents, applications humaines et services comme objets distincts ;
- livrer des parcours verticaux complets avant les fonctions avancées ;
- garder les adapters minces, versionnés et testables ;
- ne jamais forcer tous les harnesses à utiliser le même protocole modèle ;
- respecter les orchestrations multi-agent natives au lieu de les réécrire ;
- maintenir une seule source de vérité par donnée mutable ;
- faire de la compatibilité v1 une fonctionnalité transitoire explicite.

## 2. Inventaire canonique de la v1

Le registre de parité est généré à partir de `agent --help`, Compose, des répertoires persistants, des README, des tests et de `.beads/issues.jsonl`.

### 2.1 Exploitation

À préserver :

- profils `rootless-dev` et `strict-prod` ;
- onboarding, prérequis et premier démarrage ;
- `up`, `down`, `ls`, `ps`, `status`, logs et diagnostic ;
- `doctor` et suites de tests ;
- VM de validation strict-prod ;
- backup, liste et restauration ;
- cleanup et oubli sélectif ;
- update, release, snapshot et rollback ;
- réseau, tunnels et accès distants ;
- diagnostics GPU, contexte et capacité mémoire ;
- commandes modèles Ollama et TensorRT-LLM ;
- `agent ollama bench` et le runner `repo-e2e`.

### 2.2 Harnesses et runtimes agentiques

- Claude Code ;
- Codex ;
- OpenCode ;
- KiloCode ;
- Mistral Vibe/VibeStral ;
- Hermes ;
- Pi, appelé `pi-mono` dans certains tests v1 ;
- Goose ;
- OpenClaw, gateway multi-agent permanent ;
- OpenHands, objet hybride combinant application, agent platform et runtime de code.

### 2.3 Applications principalement destinées aux humains

- OpenWebUI ;
- ComfyUI et Flux ;
- Forgejo ;
- Grafana et les vues d’observabilité ;
- DGX Dashboard NVIDIA ;
- JupyterLab ;
- Portainer, uniquement comme outil administrateur de rupture.

Une application humaine ne devient pas artificiellement un `AgentRuntime`. Elle utilise un `ApplicationAdapter` et, si elle exécute du code ou des tâches GPU, un contrat spécialisé supplémentaire.

### 2.4 Services gérés

- `ollama-gate`, futur adapter du `ModelBroker` ;
- Ollama ;
- TensorRT-LLM ;
- service RAG v1 ;
- Qdrant et OpenSearch optionnel ;
- PostgreSQL ;
- reverse proxy, DNS et egress ;
- Prometheus, Loki et exporters.

### 2.5 Service RAG v1 existant

**DÉCISION :** le RAG n’est pas reconstruit dans le portail. La v1 possède déjà :

- `rag-retriever`, recherche dense et lexicale, fusion RRF et reranking ;
- `rag-worker`, indexation asynchrone et suivi des tâches ;
- Qdrant ;
- OpenSearch optionnel ;
- embeddings via le gate modèle ;
- schéma documentaire, états, healthchecks et journaux d’audit ;
- commandes `agent rag index`, `task`, `config` et `bootstrap-lexical`.

La première v2 l’utilise derrière `RAGServiceAdapter` et préserve les commandes, schémas, résultats de référence et index compatibles.

### 2.6 Skills, rôles et workflows retrouvés dans les Beads

Le Bead historique `dgx-spark-agentic-stack-dy95` mentionne : `Capability Evolver`, `Capability Evolver++`, `Clawflows`, `GOG`, `GitHub`, `Summarize`, `Knowledge Base`, `Mission Control`, `Code Reviewer`, `Decision Assistant`, `Red Team`, `Pre-Mortem`, `Literature Scout`, `Paper Reviewer`, `Grant Writer`, `Citation Auditor`, `Architecture Reviewer`, `Documentation Builder`, `Dependency Auditor`, `Test Engineer`, `Knowledge Curator`, `Knowledge Gap Detector`, `Workspace Cartographer`, `Agent Security Watcher` et `Meeting Synthesizer`.

**DÉCISION :** ces noms sont initialement des `SkillPackage`, `AgentProfile`, `WorkflowTemplate` ou connecteurs OpenClaw. Ils ne sont pas de nouveaux harnesses tant qu’une implémentation indépendante, un état propre et un cycle de vie distinct ne sont pas démontrés.

Le registre distingue toujours :

- le harness qui exécute ;
- l’identité ou le profil spécialisé ;
- les skills et outils ;
- le workflow ;
- les applications externes appelées.

Les anciens noms comme `Clawdbot` sont des alias historiques d’OpenClaw lorsqu’ils désignent la même lignée.

### 2.7 Compatibilité CLI

**DÉCISION :** `agent` reste la façade pendant la transition.

Chaque commande possède :

- un identifiant de capacité ;
- une route v1, v2 ou hybride ;
- un format JSON stable lorsqu’il existe ;
- des codes de sortie compatibles ;
- un test de parité ;
- une condition de retrait.

Le routage peut être activé par utilisateur, agent, projet et capacité.

## 3. Architecture générale

### 3.1 Monolithe modulaire de contrôle

Le plan de contrôle initial comprend :

- API FastAPI/Python ;
- worker du même codebase pour les tâches longues ;
- PostgreSQL ;
- frontend React ou Next.js ;
- REST versionné ;
- SSE ou WebSocket pour les flux ;
- outbox PostgreSQL plutôt qu’un bus distribué au départ ;
- reconciler état désiré/observé ;
- idempotence et identifiants de corrélation.

Le monolithe concerne le contrôle, pas les produits externes. Il ne recopie pas les bases internes d’OpenShell, Hermes, OpenClaw, OpenHands, Forgejo, OpenWebUI, ComfyUI, Qdrant ou du service RAG.

### 3.2 Contrats d’adaptation

- `HarnessAdapter` : protocole modèle, sessions, sous-agents, outils, permissions et surfaces ;
- `AgentRuntimeAdapter` : enveloppe d’exécution OpenShell ;
- `ApplicationAdapter` : démarrage, santé, URL, droits, sauvegarde et update d’une application ;
- `GPUJobAdapter` : admission et observation d’une tâche GPU, notamment ComfyUI ;
- `ManagedServiceAdapter` : service interne ;
- `ModelBrokerAdapter` : protocoles et backends modèles ;
- `RAGServiceAdapter` : service RAG v1 ;
- `GitProviderAdapter` : Forgejo/GitHub ;
- `ExternalAccessBroker` : GitHub, Hugging Face et futurs services externes.

OpenHands utilise plusieurs contrats : application, harness et runtime. Les adapters exposent les capacités disponibles ; ils ne simulent pas une capacité absente.

### 3.3 Zones de confiance

| Niveau | Exemples | Exigence |
|---|---|---|
| contrôle de confiance | API, portail, scheduler, brokers | privilèges minimaux et audit complet |
| services gérés | PostgreSQL, Forgejo, RAG, Grafana | Docker/Compose durci et réseau interne |
| applications extensibles | OpenWebUI, ComfyUI, JupyterLab | plugins contrôlés, droits minimaux |
| exécution de code | agents, OpenHands runtime, outils autonomes | OpenShell cible |
| rupture | Portainer, shell hôte, TUI OpenShell direct | admin, réauthentification, audit |

Une interface web n’est pas automatiquement un service de confiance.

### 3.4 Déploiement

- Docker/Compose exécute les services gérés ;
- OpenShell utilise initialement son pilote Docker ;
- les agents n’accèdent jamais au socket Docker ;
- Kubernetes n’est pas requis pour la v2 mono-DGX ;
- MicroVM et Kubernetes restent des drivers futurs ;
- aucun parcours utilisateur ne dépend d’un nom de conteneur ou d’un port interne.

## 4. Sources de vérité

| Domaine | Source canonique | Projection |
|---|---|---|
| utilisateurs, projets, rôles | PostgreSQL contrôle | portail |
| définitions et profils agents | PostgreSQL + manifestes Git | harness/OpenShell |
| état désiré runtime | plan de contrôle | reconciler |
| état observé sandbox | OpenShell | PostgreSQL |
| sessions/conversations | harness natif | références PostgreSQL |
| arbre multi-agent | harness natif | projection pour quotas/audit |
| dépôts internes | Forgejo/Git | références contrôle |
| dépôts GitHub | GitHub | références et miroirs autorisés |
| workspaces | stockage persistant | montages runtime |
| secrets | SecretStore | credentials temporaires |
| catalogue modèles | plan de contrôle | ModelBroker |
| fichiers modèles | store global | catalogue et empreintes |
| sources RAG | emplacement original | catalogue PostgreSQL |
| logique RAG | `rag-retriever` | adapter |
| tâches RAG | `rag-worker` | progression contrôle |
| index dense | Qdrant, régénérable | snapshots |
| index lexical | OpenSearch, régénérable | snapshots |
| logs | Loki ou store structuré | liens contrôle |
| métriques | Prometheus | Grafana |

Aucune donnée mutable ne possède deux sources actives.

## 5. Identité, projet, session et multi-agent

### 5.1 Objets

- `AgentDefinition` : harness, version, image, capacités et surfaces ;
- `AgentIdentity` : collaborateur logique persistant ;
- `RuntimeContext` : exécution pour utilisateur + agent + projet ;
- `Session` : conversation ou tâche native ;
- `Run` : exécution corrélée, éventuellement parent ou enfant ;
- `Project` : droits, workspace, secrets, modèles et collections.

### 5.2 Contextes

La clé d’un contexte est :

```text
utilisateur + identité d’agent + projet
```

Le contexte sans projet est personnel. Changer de projet rejoint ou crée un autre `RuntimeContext`, car les politiques fichiers OpenShell sont fixées à la création.

```bash
agent codex
agent codex ARTANY
agent project SEGMENTATION-RTMRI
```

### 5.3 Persistance

- reconnexion chaude : sandbox et processus vivants ;
- reprise froide : recréation depuis image, manifeste et politique, puis rattachement de l’état ;
- reprise native : mécanisme du harness ;
- checkpoint mémoire : seulement si réellement supporté.

Un HOME mutable partagé entre projets est interdit par défaut.

### 5.4 Orchestration multi-agent

Hermes, OpenClaw, OpenHands, Goose, KiloCode, OpenCode, Claude Code et certaines extensions Pi peuvent créer des sous-agents.

Chaque profil déclare :

- `orchestration_mode` : `none`, `native`, `platform` ou `external-provider` ;
- profondeur et concurrence maximales ;
- annulation, reprise et inspection ;
- héritage des outils, modèles, secrets et droits ;
- remontée d’usage par enfant.

Invariants :

- un enfant ne reçoit jamais plus de droits que son parent et son projet ;
- CPU, mémoire, GPU, tokens, coûts et accès externes sont agrégés sur l’arbre ;
- chaque événement porte `run_id` et `parent_run_id` ;
- annulation et drainage des orphelins sont testés ;
- la délégation inter-harness est interdite par défaut ;
- les cycles Hermes → Goose → Codex → Hermes sont refusés ;
- la plateforme ne remplace pas l’orchestration native ; elle impose l’enveloppe de ressources et de sécurité.

## 6. ModelBroker et compatibilité des harnesses

### 6.1 Contrat

`ModelBroker` est la capacité cible. `ollama-gate` est l’adapter v1 jusqu’à décision documentée de l’étendre ou de le remplacer.

Responsabilités :

- APIs réellement nécessaires aux clients ;
- catalogue, alias et santé des modèles ;
- routage Ollama, TensorRT-LLM, vLLM ou fournisseur distant ;
- embeddings ;
- streaming ;
- identité signée utilisateur/agent/projet/run ;
- quotas, priorité, usage et coûts ;
- fallback explicite ;
- admission GPU avec le scheduler.

OpenShell contrôle l’autorisation réseau et injecte un credential court. Il ne possède ni le catalogue global, ni les quotas projet, ni le scheduler.

### 6.2 `inference.local`

`inference.local` est réservé aux profils à modèle fixe. Pour le routage dynamique, le sandbox joint directement le ModelBroker interne par une route OpenShell autorisée. Les backends Ollama/TRT/vLLM restent inaccessibles aux agents.

### 6.3 Protocoles par composant

| Composant | Protocole à préserver | Validation obligatoire |
|---|---|---|
| Claude Code | Anthropic Messages `/v1/messages` | outils, streaming, usage, hooks, sous-agents |
| Codex | OpenAI Responses `/v1/responses` | événements, outils, approvals, erreurs |
| OpenCode | Chat Completions ou Responses selon provider | agents, permissions, serveur headless |
| KiloCode | Ollama natif ou OpenAI-compatible | contexte, timeouts, outils, sous-agents |
| Vibe | endpoint compatible configuré | agents TOML, trust projet, ACP, hors ligne |
| Pi | Chat, Responses, Messages ou extension | drapeaux compatibilité, extensions |
| Goose | provider d’extension/recipe | recipes, ACP, sous-agents externes |
| Hermes | `chat_completions`, `codex_responses` ou `anthropic_messages` | profils, délégation et dashboard |
| OpenClaw | Ollama/OpenAI-compatible par agent | sessions, canaux, outils, sous-agents |
| OpenHands | backend LiteLLM/OpenAI-compatible retenu | outils, streaming, coût, SDK |
| OpenWebUI | API OpenAI ModelBroker | modèles, streaming, RBAC, outils autorisés |

Un simple `Hello` ne prouve pas la compatibilité. Les tests couvrent tool calling, contexte, usage, erreurs, streaming et fonctions multi-agent.

`ollama launch` sert d’oracle de configuration pour les intégrations qu’il supporte, notamment Claude Code, Codex, OpenCode, Pi et OpenClaw. La production utilise ensuite des profils versionnés générés par la stack.

## 7. OpenShell, NemoClaw, Hermes et OpenHands

### 7.1 OpenShell

**CIBLE :** runtime principal des agents, derrière `AgentRuntimeAdapter`.

Limites intégrées au design :

- projet encore alpha et initialement mono-utilisateur ;
- politiques fichiers/processus statiques à la création ;
- pas de scheduler global ;
- limites CPU/mémoire appliquées par le driver, admission globale externe ;
- GPU et APIs ressources à valider ;
- pas de checkpoint générique supposé ;
- upgrade susceptible de recréer les sandboxes.

Le plan de contrôle est la frontière multi-utilisateur et le seul client normal de la gateway.

### 7.2 OpenClaw avec ou sans NemoClaw

NemoClaw est privilégié pour OpenClaw seulement après parité complète : gateway, agents, workspaces, `agentDir`, sessions, mémoire, skills, canaux, approvals, relay, pièces jointes, Control UI et sous-agents.

OpenClaw reste propriétaire de son arbre d’agents, de ses bindings de canaux et de ses sessions. Le plan de contrôle projette l’état pour quotas et audit sans l’aplatir.

### 7.3 Deux chemins Hermes

**Hermes natif — référence de production :**

- `HermesNativeAdapter` dans une enveloppe OpenShell ;
- profils indépendants, configurations, mémoire, sessions, skills, cron, messageries et base d’état ;
- dashboard web, Chat et Desktop ;
- sous-agents natifs isolés ;
- Kanban durable partagé entre profils ;
- limites de concurrence, profondeur et budget ;
- protocole modèle choisi par profil.

**Hermes NemoClaw — canari :**

- `HermesNemoClawAdapter` et blueprint épinglé ;
- racine d’état indépendante ;
- aucun partage en écriture de `HERMES_HOME`, sessions ou base avec le natif ;
- imports/exports en dry-run ;
- activation seulement après parité CLI, dashboard, profils, mémoire, outils, délégation, Kanban, cron, messageries, Desktop et reprise.

Si la parité échoue, Hermes natif reste le chemin de production.

### 7.4 OpenHands et la double sandbox

OpenHands est une application et un harness multi-agent avec son propre runtime. M2 compare :

1. UI/contrôle OpenHands avec agent-server piloté par OpenShell ;
2. runtime natif derrière une enveloppe externe minimale ;
3. intégration directe de l’Agent SDK OpenHands.

Le choix préserve sous-agents, terminal, navigateur, fichiers, WebSocket, GitHub et reprise. L’édition locale étant mono-utilisateur, la v2 utilise une instance par utilisateur/domaine de sécurité ou une édition officiellement multi-tenant. Aucune superposition de sandboxes n’est acceptée sans bénéfice mesuré.

## 8. Profils d’intégration des harnesses v1

Chaque profil contient version amont, digest, architecture ARM64, protocole modèle, fichiers persistants, surfaces, permissions, sous-agents et tests.

| Harness | État à préserver | Particularités |
|---|---|---|
| Claude Code | `CLAUDE.md`, `.claude/agents`, hooks, plugins/skills, MCP, sessions utiles | hooks de permission, sous-agents avec outils propres, Messages API |
| Codex | `config.toml`, providers, sessions, approvals, règles sandbox | Responses API, CLI principal, app/IDE optionnels |
| OpenCode | `opencode.json`, auth séparée, agents, permissions, sessions | Chat ou Responses explicite, serveur headless protégé |
| KiloCode | `.kilo/agents`, modes, permissions, sessions | CLI, IDE, console web, sous-agents natifs, contexte benchmarké |
| Vibe | `VIBE_HOME`, `config.toml`, agents TOML, `AGENTS.md`, skills | CLI/VS Code/ACP, trust répertoires, local hors ligne, cloud désactivé par défaut |
| Pi | modèles, packages/extensions, sessions | minimal par défaut ; aucun sous-agent supposé sans package épinglé ; auth hors workspace |
| Goose | recipes, extensions, sessions, ACP | sous-agents internes/externes, garde anti-récursion |
| Hermes | profils, dashboard, mémoire, sessions, skills, cron, Kanban | natif et NemoClaw séparés, multi-agent natif |
| OpenClaw | gateway, agents, `agentDir`, sessions, canaux, relay, UI | processus permanent, multi-agent/multi-canal |
| OpenHands | UI, settings, conversations, skills/hooks, GitHub, runtime | application + harness ; stratégie sandbox et utilisateur explicites |

Les tests vérifient le vrai binaire officiel, pas seulement un wrapper présent dans le PATH. Ils valident la configuration attendue par la version amont, afin d’éviter les faux positifs déjà rencontrés avec Vibe.

## 9. Applications humaines

### 9.1 Portail

Accueil : agents visibles. Sections séparées :

- Agents ;
- Applications ;
- Projets ;
- Modèles ;
- Ressources ;
- Données/RAG ;
- Système.

Une application peut invoquer un modèle ou un agent sans devenir une identité d’agent.

### 9.2 Profils applicatifs

| Application | Contrat | Exigences |
|---|---|---|
| OpenWebUI | `ApplicationAdapter` | multi-utilisateur/RBAC, ModelBroker uniquement, sauvegarde |
| ComfyUI | `ApplicationAdapter` + `GPUJobAdapter` | WebSocket/API, Flux, racine persistante unique, admission GPU |
| Forgejo | `ApplicationAdapter` + `GitProviderAdapter` | forge interne, comptes, SSH, hooks, branches protégées |
| Grafana | `ApplicationAdapter` | dashboards/datasources versionnés, lecture majoritaire |
| DGX Dashboard | launcher admin supporté | pas d’iframe/proxy supposé sans test |
| JupyterLab | application de code | isolation utilisateur, quotas, accès externes explicites |
| Portainer | break-glass | désactivé par défaut, admin uniquement |

### 9.3 Extensions à risque

- OpenWebUI Tools, Functions et Pipelines peuvent exécuter du Python : création/import désactivés par défaut, allowlist et revue ;
- le RAG natif OpenWebUI ne devient pas une seconde source de vérité : il est désactivé ou relié explicitement au RAG de la stack ;
- ComfyUI custom nodes sont du code tiers : versions/digests, provenance, allowlist, scan et test ;
- JupyterLab est traité comme un environnement de code, pas une simple page web ;
- les tâches OpenHands restent sous leur politique runtime validée.

### 9.4 Surfaces natives

- Hermes Dashboard et Desktop ;
- OpenHands UI ;
- Kilo CLI/IDE/console ;
- Vibe CLI/VS Code/ACP ;
- Goose ACP ;
- OpenWebUI, ComfyUI, Forgejo et Grafana ;
- DGX Dashboard et JupyterLab.

Aucun iframe ou reverse proxy par sous-chemin n’est supposé compatible sans preuve. Le portail utilise une URL, un tunnel ou un proxy officiellement validé.

## 10. Secrets, GitHub et Hugging Face

### 10.1 SecretStore

Une seule source canonique assure chiffrement, scopes, rotation, expiration et audit. Aucune valeur secrète n’est stockée dans PostgreSQL, logs, RAG, image ou HOME persistant.

Les providers OpenShell et les fichiers temporaires de service sont des mécanismes de livraison, pas des sources de vérité.

### 10.2 ExternalAccessBroker

Les agents peuvent accéder à GitHub et Hugging Face par capacités explicites.

Capacités minimales :

- `github.contents.read/write` ;
- `github.pull_requests.read/write` ;
- `github.issues.read/write` ;
- `github.actions.read`, les droits d’administration étant séparés ;
- `hf.models.read/write` ;
- `hf.datasets.read/write` ;
- `hf.spaces.read/write`.

#### GitHub

- préférer une GitHub App avec jeton d’installation court, dépôts sélectionnés et permissions minimales ;
- utiliser un PAT finement granulaire par utilisateur si nécessaire ;
- distinguer clone/fetch, push, branche, PR, issue, release et workflow ;
- exiger une politique ou une approbation pour les écritures, releases et workflows ;
- conserver Forgejo comme forge interne canonique ; synchronisation ou miroir GitHub seulement si demandé.

#### Hugging Face

- tokens fins limités aux ressources nécessaires ;
- lecture et publication séparées ;
- cache central `snapshot_download`/HF Hub pour éviter les téléchargements dupliqués ;
- révision, digest, licence et provenance enregistrés ;
- publication, suppression et modification de model card soumises à autorisation ;
- téléchargements lourds soumis au scheduler et aux budgets disque/réseau.

Les credentials courts sont liés à utilisateur, agent, projet et run. `git`, `gh`, `huggingface_hub`, CLI HF ou MCP GitHub les consomment temporairement. Les politiques OpenShell limitent domaines, méthodes et chemins.

## 11. Scheduler et ressources

Le scheduler possède :

- admission CPU, mémoire unifiée, GPU, stockage et réseau ;
- files, priorités et quotas ;
- modes normal, burst et exclusif ;
- réservations et calendrier ;
- drain et délai de grâce ;
- coordination ModelBroker, ComfyUI, OpenHands et téléchargements HF ;
- agrégation parent/enfants des harnesses multi-agent ;
- séparation interactif/tâche de fond.

Progression : limites fixes, métriques/refus, files, réservations, préemption coopérative, optimisation adaptative. Aucune préemption forcée n’est promise avant validation de la reprise des tâches.

OpenShell applique les limites d’une sandbox mais ne remplace pas ce scheduler.

## 12. RAG, documents et autorisations par lot

### 12.1 Baseline v1

M0 capture : versions, configuration, modèle et dimension d’embedding, schéma, collections Qdrant, index OpenSearch, nombres de documents/chunks, tâches, corpus de référence, requêtes/résultats, état de dry-run, volumes, latence et journaux.

### 12.2 `RAGServiceAdapter`

- `health`, `capabilities`, `config` ;
- soumission, statut et annulation de tâche ;
- `retrieve` ;
- liste des collections ;
- snapshot/restore ;
- reconstruction ;
- usage.

Le plan de contrôle possède catalogue, droits, provenance, autorisation d’indexer et politiques. Le service RAG possède ingestion technique, chunking, embeddings, index, fusion, reranking et état détaillé des tâches.

### 12.3 Multi-projet

La v2 ajoute côté serveur :

- identité signée utilisateur/agent/projet/run ;
- collection séparée ou filtre payload obligatoire ;
- ACL avant recherche et restitution ;
- refus des sources devenues inaccessibles ;
- audit du scope et des sources retournées ;
- tests de fuite inter-projet.

Le choix collection par projet, domaine de confidentialité ou collection filtrée est décidé en M2.

### 12.4 Autorisations documentaires par lot

`AuthorizationBatch` permet d’autoriser globalement un ensemble de documents selon :

- fichiers, dossier, collection, projet, type, étiquette ou requête ;
- action : lire, indexer, rechercher, partager, publier ou supprimer ;
- bénéficiaires : utilisateurs, groupes, agents ou classes d’agents ;
- portée : projet, organisation ou globale ;
- expiration, date de revue ou nombre d’utilisations ;
- exclusions obligatoires pour secrets, données réglementées et refus explicites.

Un dry-run affiche nombre, volume, classifications, projets et exclusions. L’option « autoriser globalement tous les documents correspondants » est disponible à l’administrateur, explicite, révocable et auditée. Aucun wildcard caché ne contourne les ACL.

Les grants sont appliqués côté serveur par le service RAG et les montages fichiers.

### 12.5 Versionnement et restauration

Un changement de modèle, dimension, chunking ou schéma crée une nouvelle version d’index avec modèle/digest, dimension, sources et collections associées. La réindexation se fait en parallèle, puis bascule atomique après validation.

Migration : gel des indexations, export config/schéma, snapshot Qdrant, sauvegarde OpenSearch, états worker/retriever, restauration isolée et requêtes de référence. Aucun ancien index n’est supprimé automatiquement.

## 13. Migration

### 13.1 Pattern d’étranglement

`agent` route chaque capacité vers v1 ou v2. La migration se fait par parcours vertical :

```text
utilisateur → CLI/portail → identité → projet → harness/application
→ runtime → modèle → workspace/données → accès externes → logs → sauvegarde
```

Aucun parcours n’est migré s’il exige une commande Docker/OpenShell manuelle.

### 13.2 Données

- racines v1/v2 distinctes ;
- modèles partagés en lecture seule pendant l’ombre ;
- aucune double écriture ;
- importeurs versionnés, idempotents et dry-run ;
- gel/import final/test/rollback par domaine ;
- exports natifs PostgreSQL, Forgejo, Qdrant et applications ;
- workspaces snapshotés ;
- secrets archivés séparément et chiffrés.

## 14. Phases

### M0 — Preuves v1

Inventaire commandes/services/Beads, baseline ressources, `agent ollama bench`, `repo-e2e`, sauvegarde/restauration, baseline RAG et catalogue skills.

**G0 :** v1 restaurée et 100 % des capacités visibles.

### M1 — Contrats

Sources de vérité, adapters, classification harness/application/service/skill, profils d’intégration amont, protocoles modèles et modèle multi-agent.

**G1 :** aucune responsabilité dupliquée ou sans propriétaire.

### M2 — Spikes bloquants sur DGX

- OpenShell ARM64, ressources et isolation ;
- chaque protocole modèle réel et comparaison `ollama launch` ;
- Hermes natif/NemoClaw ;
- OpenClaw NemoClaw ;
- stratégie sandbox OpenHands ;
- sous-agents et budgets ;
- GitHub/HF credentials courts et cache ;
- ACL RAG, `AuthorizationBatch` et snapshots ;
- surfaces web/desktop ;
- SecretStore ;
- benchmarks de sécurité matérielle.

**G2 :** chaque hypothèse est validée, remplacée ou abandonnée avec preuve.

### M3 — Walking skeleton

Un utilisateur, Codex, contexte personnel/projet, CLI, portail minimal, OpenShell, ModelBroker, workspace, reprise, logs, backup, lecture GitHub et téléchargement HF en cache.

**G3 :** parcours complet sans manipulation d’infrastructure.

### M4 — Fondation production

Auth, rôles, délégations, reconciler, SecretStore, ExternalAccessBroker, audit, observabilité, admission simple et upgrade épinglé.

**G4 :** séparation utilisateurs/projets et restauration validées.

### M5 — Modèles

Contrat ModelBroker, décision sur `ollama-gate`, Ollama/TRT/remote, embeddings, quotas, admission et tests Messages/Responses/Chat/Ollama.

**G5 :** aucun accès backend direct et parité des commandes modèle.

### M6 — Agents de code

Claude, Codex, OpenCode, Kilo, Vibe, Pi et Goose avec profils, protocoles, extensions, surfaces, sous-agents, GitHub/HF et `repo-e2e`.

**G6 :** contrat vertical et tests négatifs verts pour chaque agent.

### M7 — Hermes, OpenClaw, OpenHands

Hermes natif référence, NemoClaw canari isolé, OpenClaw NemoClaw après parité, choix runtime OpenHands, arbres multi-agent, dashboards, canaux et reprise.

**G7 :** aucune double écriture, double orchestration ou double sandbox non justifiée.

### M8 — Applications humaines

OpenWebUI, ComfyUI/Flux, Forgejo, Grafana, DGX Dashboard et JupyterLab avec RBAC, plugins gouvernés, admission GPU et sauvegarde.

**G8 :** accès sans port interne et selon le niveau de confiance.

### M9 — RAG et documents

Adapter v1, collections/index, identité/ACL, versions, `AuthorizationBatch`, portail et mémoire globale/projet.

**G9 :** parité des requêtes, aucune fuite, snapshots restaurés.

### M10 — Scheduler avancé et collaboration

Files, réservations, calendrier, préemption coopérative, Mattermost/Dify, bots et garde anti-boucle.

**G10 :** charge maîtrisée sans casser l’interactif.

### M11 — Ombre et canaris

Tâches miroir, canaris par utilisateur/agent/application, benchmark complet, endurance, gel/import par domaine et rollback chronométré.

**G11 :** deux cycles représentatifs sans perte ni incident matériel.

### M12 — Retrait

Retrait des routes v1 validées et du fallback Docker agent lorsqu’inutile. Archives conservées, nettoyage proposé mais jamais automatique.

## 15. Tests et benchmarks DGX Spark

### 15.1 Contrats et sécurité

- CLI v1/v2 et APIs ;
- adapters ;
- protocoles modèles ;
- imports/exports ;
- refus fichiers/réseau/processus ;
- fuite inter-projet ;
- secrets absents des sorties ;
- droits GitHub/HF ;
- ACL et lots documentaires ;
- actions admin réauthentifiées.

### 15.2 Résilience

Redémarrage API, worker, OpenShell, harness, application et backend modèle ; sandbox perdue ; réseau coupé ; disque presque plein ; téléchargement interrompu ; migration interrompue ; restauration racine vierge ; reconstruction RAG.

### 15.3 Suite DGX Spark

La baseline attend une DGX Spark ARM64 avec 128 Go de mémoire unifiée ; les caractéristiques effectives sont détectées et enregistrées, jamais supposées suffisantes.

**Niveau 0 — matériel :** CPU/GPU, mémoire/bande passante, stockage, réseau, températures, puissance, fréquences, throttling et erreurs.

**Niveau 1 — modèles :** chargement/déchargement, mémoire résidente, TTFT, prefill/decode tokens/s, streaming, contextes 8k/32k/64k+, outils et concurrence 1/2/4/8 selon admission.

**Niveau 2 — harnesses :** démarrage chaud/froid, reprise, compaction, `repo-e2e`, Git/GitHub, approvals, sous-agents, profondeur, annulation et coûts.

**Niveau 3 — applications/données :** OpenWebUI, Flux ComfyUI, tâche OpenHands, RAG index/query, Forgejo, GitHub, HF cache froid/chaud.

**Niveau 4 — mixte/endurance :** charges 1 h, 6 h et 24 h, panne backend, pression disque, perte réseau et échec de modèle.

Coupe-circuits : température, erreurs GPU, mémoire disponible, swap, disque et latence du contrôle. La montée en charge est progressive, avec cooldown. Les seuils d’admission sont dérivés des mesures en réservant explicitement les ressources de l’OS et des services critiques.

Les smoke tests CI restent bornés. Les benchmarks lourds ont une fenêtre dédiée et ne chargent jamais plusieurs gros modèles sans admission. Les artefacts enregistrent firmware, noyau, driver, digests, modèles, versions et commit.

Une release est bloquée sur régression au-delà des budgets validés ou sur OOM, reboot, corruption, fuite de secret ou throttling durable.

## 16. Risques bloquants

| Risque | Traitement |
|---|---|
| OpenShell alpha/mono-utilisateur initial | adapter, pinning, spike isolation |
| protocole modèle uniformisé | matrice Messages/Responses/Chat/Ollama |
| double orchestration | arbre corrélé, mode natif déclaré, anti-cycle |
| Hermes natif/NemoClaw partageant un état | racines séparées et promotion contrôlée |
| OpenHands multi-tenant supposé | instance/domaine isolé ou édition adaptée |
| double sandbox OpenHands | décision M2 mesurée |
| tokens GitHub/HF persistants | ExternalAccessBroker et credentials courts |
| téléchargements HF dupliqués | cache central et admission |
| RAG OpenWebUI parallèle | désactivation ou pont explicite |
| Tools OpenWebUI/custom nodes ComfyUI | allowlist, pinning, scan, sandbox |
| changement embedding | version d’index séparée |
| Qdrant pris pour source canonique | sources et catalogue restaurables |
| proxy dashboard supposé | chemin officiel testé |
| sauvegarde fichier incohérente | exports natifs orchestrés |
| surcharge DGX | benchmark, réserve, admission, coupe-circuits |
| réécriture trop large | walking skeleton et vertical slices |

## 17. Update et exploitation

- versions et digests épinglés ;
- matrice de compatibilité plateforme/harnesses/apps/modèles ;
- aucune mise à jour automatique de production ;
- validation dans racine/VM de test ;
- rollback code par digest ;
- rollback données par restauration ;
- SBOM, provenance et scan ;
- mode break-glass ;
- runbooks incidents, capacité, backup et restauration.

## 18. Définition de terminé

La v1 ne peut être retirée que si :

- toutes ses capacités ont une décision et un test ;
- chaque harness/application possède un profil validé contre sa documentation amont ;
- CLI et portail sont utilisables sans connaissance de l’infrastructure ;
- les sources de vérité sont uniques et restaurables ;
- le protocole modèle natif de chaque harness fonctionne ;
- les sous-agents natifs sont gouvernés sans double orchestration ;
- Hermes natif est opérationnel et le statut NemoClaw décidé par parité ;
- OpenHands possède une stratégie runtime et utilisateur démontrée ;
- GitHub et Hugging Face utilisent des capacités minimales et credentials temporaires ;
- agents et applications humaines restent correctement séparés ;
- le service RAG v1 conserve ses capacités, ACL et restauration ;
- `AuthorizationBatch` est audité et révocable ;
- les applications exécutant du code sont gouvernées ;
- benchmarks, endurance et coupe-circuits définissent une enveloppe sûre DGX Spark ;
- update, rollback et restauration ont été répétés ;
- une personne peut diagnostiquer, sauvegarder, restaurer et mettre à jour avec les runbooks ;
- l’administrateur approuve explicitement chaque retrait v1.
