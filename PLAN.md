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

Les campagnes d’optimisation sont des charges de fond interruptibles, de priorité inférieure aux usages interactifs et aux réservations explicites. Elles doivent pouvoir être mises en pause, drainées puis reprises sans perdre leurs preuves. Un administrateur dispose d’un arrêt global immédiat ; après cet arrêt, aucune campagne ne redémarre sans autorisation explicite. Une campagne ne préempte jamais une charge utilisateur prioritaire. Ces propriétés sont P0.

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

### M3U — Première version utilisable

Un utilisateur peut se connecter, lancer Codex dans un contexte personnel ou projet, suivre l’exécution, interrompre puis reprendre une session, accéder aux fichiers produits et comprendre un échec sans connaître Docker, OpenShell, les ports internes ni la disposition des services. Un administrateur peut installer, diagnostiquer, sauvegarder et restaurer ce périmètre par les surfaces officielles. M3U inclut uniquement le minimum de M4 nécessaire à ces parcours.

**G3U :** ces parcours réussissent de bout en bout, leurs erreurs principales sont actionnables et leur récupération est testée avec la boucle produit/runtime.

Non-objectifs de cette première version :

- intégrer simultanément tous les harnesses et toutes les applications ;
- unifier toutes les interfaces natives ;
- introduire Kubernetes ;
- livrer d’emblée le scheduler avancé ou optimal ;
- remplacer le RAG v1 lorsqu’il fonctionne derrière son adapter ;
- laisser une capacité hors des parcours M3U retarder la livraison, sauf dépendance P0 démontrée.

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

### 15.4 Boucles d’optimisation automatique de l’implémentation v2

**DÉCISION :** l’implémentation de la v2 est pilotée par deux boucles automatiques complémentaires et normatives :

1. une **boucle produit/runtime**, qui mesure si les parcours réels réussissent de manière sûre, efficiente et récupérable ;
2. une **boucle d’ingénierie**, qui mesure si l’architecture reste rapide à modifier, vérifiable, réversible et résistante aux régressions.

Ces boucles sont applicables dès M0 pour établir la baseline v1, deviennent obligatoires pour le walking skeleton M3 et conditionnent ensuite toute promotion. Elles ne remplacent pas les gates G0 à G11 : elles fournissent les preuves machine qui permettent de les déclarer satisfaits.

#### 15.4.1 Principe de décision : gates puis frontière de Pareto

Une implémentation candidate est évaluée en deux temps :

1. les critères éliminatoires sont vérifiés ; tout échec rejette ou met en quarantaine le candidat ;
2. les candidats admissibles sont comparés sur une frontière de Pareto, sans score pondéré unique susceptible de masquer une dégradation critique.

Un candidat est **dominé** s’il n’est meilleur sur aucune métrique retenue et s’il est moins bon sur au moins une métrique, au-delà de la marge d’incertitude et de l’effet minimal significatif définis dans le manifeste d’évaluation.

Une promotion automatique exige que le candidat :

- franchisse tous les gates P0 ;
- respecte les règles de non-infériorité P0/P1/P2 ;
- ne soit pas dominé par la dernière version saine ou par un candidat conservé sur la frontière ;
- améliore au moins une métrique au-delà de son effet minimal significatif, ferme un échec connu ou réduit une dette technique mesurée ;
- possède un rollback testé et des artefacts complets ;
- ne repose sur aucune tolérance expirée.

#### 15.4.2 Classification hybride P0, P1 et P2

La criticité est définie par une liste P0 explicite, puis par des règles de classement P1/P2. Une capacité peut être surclassée manuellement. Une capacité P0 ne peut jamais être déclassée automatiquement.

**P0 non négociable :**

- absence de fuite de secrets ou de données entre utilisateurs, projets et domaines de sécurité ;
- intégrité des données, source de vérité unique et absence de double écriture incohérente ;
- migrations idempotentes avec dry-run, validation, restauration et rollback ;
- absence d’accès direct non autorisé au socket Docker, aux backends modèles et aux services internes ;
- respect des droits, quotas et agrégation des ressources des arbres multi-agents ;
- annulation des descendants, drainage des orphelins et refus des cycles de délégation ;
- audit corrélé complet des actions sensibles ;
- absence de reboot, corruption, OOM répété, erreur GPU persistante ou throttling durable ;
- arrêt administratif immédiat des campagnes d’optimisation, sans redémarrage automatique ni préemption d’un usage prioritaire ;
- capacité démontrée à restaurer la dernière version saine ;
- capacité démontrée à restituer la DGX dans l’état de référence enregistré lorsqu’une restitution est demandée.

**Règles automatiques :** une capacité touchant aux secrets, droits, données mutables, migrations, identité, isolation, accès externes, GPU, rollback ou cycle de vie multi-agent est P0. Une capacité nécessaire à un parcours utilisateur supporté, à l’observabilité ou à la compatibilité v1 est P1. Une capacité expérimentale, de confort ou non requise pour un parcours supporté est P2, sauf surclassement explicite.

Le registre versionné des capacités contient au minimum : `capability_id`, description, propriétaire, classe, justification, oracle, corpus, métriques, dépendances et règle de retrait.

#### 15.4.3 Tolérances temporaires

Une tolérance n’est possible que pour une exigence P1 ou P2 non liée à la sécurité, à l’isolation, aux secrets, à l’intégrité des données ou à la récupérabilité P0.

Chaque tolérance est un objet versionné contenant :

- `waiver_id` et `capability_id` ;
- écart maximal autorisé ;
- justification et preuve ;
- responsable ;
- Bead associé ;
- date de création et date d’expiration ;
- test prouvant sa suppression ;
- statut `active`, `expired`, `removed` ou `revoked`.

Une tolérance expirée bloque toute promotion. L’évaluateur candidat ne peut ni créer, ni prolonger, ni élargir une tolérance.

#### 15.4.4 Non-infériorité par rapport à la v1

La v1 est exécutée plusieurs fois en M0 afin de mesurer sa variabilité avant toute comparaison. Les baselines sont épinglées par commit, configuration, corpus, versions, modèles, matériel et conditions thermiques.

Pour le taux de réussite sûr et récupérable, la promotion exige que la borne inférieure à 95 % de la différence appariée `TPSR_v2 - TPSR_v1` respecte :

- P0 : `>= 0,00` ;
- P1 : `>= -0,03`, uniquement avec une tolérance active ;
- P2 : `>= -0,05`, uniquement avec une tolérance active.

Sans tolérance active, P1 et P2 doivent également être non inférieurs. Une moyenne favorable ne compense jamais une borne inférieure non conforme.

#### 15.4.5 Boucle produit/runtime

Le critère principal est le **TPSR — taux de parcours sûrs et récupérables** :

```text
TPSR = nombre de parcours fonctionnellement réussis,
       sans violation de gate et avec récupération validée
       / nombre total de tentatives valides
```

Une tentative n’est comptée comme réussite que si :

- le résultat fonctionnel satisfait l’oracle ;
- les droits, l’isolation, les quotas et l’audit sont conformes ;
- aucune ressource orpheline ou altération non déclarée n’est créée ;
- la panne injectée, lorsqu’elle fait partie du scénario, est détectée et récupérée ;
- les artefacts nécessaires au diagnostic sont complets.

La boucle produit mesure au minimum :

- TPSR observé et borne inférieure à 95 % ;
- taux de réussite par capacité et par classe P0/P1/P2 ;
- latence médiane et p95 ;
- temps de démarrage froid et chaud ;
- GPU-secondes, CPU-secondes et pic de mémoire unifiée ;
- tokens et coût externe lorsqu’ils existent ;
- énergie mesurée ou estimée, avec méthode enregistrée ;
- interventions humaines ;
- temps de détection et temps de récupération ;
- taux de rollback et de restauration réussis ;
- erreurs, retries, timeouts et ressources orphelines.

Les objectifs de Pareto maximisent le TPSR et minimisent la latence, les ressources, le coût, les interventions et le temps de récupération. Une métrique indisponible est `null` avec une justification ; elle ne vaut jamais zéro implicitement.

Les cinq parcours initiaux obligatoires du walking skeleton sont :

1. bootstrap, démarrage et `doctor` ;
2. Codex : modifier, tester, committer et pousser un dépôt autorisé ;
3. isolation personnel/projet avec test négatif de fuite ;
4. panne d’un backend modèle, fallback explicite et récupération ;
5. snapshot, mutation, restauration et rollback.

Le corpus est ensuite étendu aux harnesses, applications, RAG, multi-agent, scheduler et migrations décrits dans ce plan.

#### 15.4.6 Boucle d’ingénierie et de changeabilité

La boucle d’ingénierie part d’un commit candidat et demande à un agent évaluateur indépendant d’effectuer des modifications représentatives dans un workspace jetable. Le résultat n’est pas fusionné : il sert à mesurer la qualité de l’architecture candidate.

Le corpus est hiérarchisé :

- **rapide, à chaque modification** : ajouter une variable de configuration, une commande CLI ou une règle simple ;
- **complet, avant promotion** : ajouter un adapter modèle, une application, une migration de données, une règle de quota GPU ou une capacité d’audit ;
- **évolutif** : toute régression ou difficulté réelle produit un scénario candidat, placé en quarantaine avant de rejoindre le corpus de référence.

La boucle mesure au minimum :

- temps jusqu’au premier résultat vert et temps total jusqu’à validation ;
- taux de réussite au premier essai et nombre d’itérations ;
- nombre de fichiers, modules et contrats modifiés ;
- taille du diff, enregistrée mais jamais optimisée isolément ;
- violations des frontières architecturales ;
- couverture des tests et mutation score lorsque pertinent ;
- régressions fonctionnelles ou de sécurité introduites ;
- duplication ajoutée ou supprimée ;
- complexité et dette technique selon les analyseurs épinglés ;
- temps de revert ou de rollback ;
- complétude de la documentation, des migrations et des tests négatifs.

Un changement plus petit n’est pas automatiquement meilleur : la mesure porte sur la localisation correcte des responsabilités, la vérifiabilité et la réversibilité, pas sur la seule quantité de code.

#### 15.4.7 Corpus visibles, cachés et évolutifs

Chaque corpus possède un identifiant immuable et un `corpus_version`. Il comprend :

- des scénarios visibles stables, utilisables pour le développement ;
- des scénarios cachés stables, inaccessibles à la branche candidate ;
- des scénarios issus des incidents, régressions, limites et migrations réelles.

Un nouveau scénario reste en quarantaine jusqu’à ce qu’il ait :

- un oracle non ambigu ;
- réussi au moins trois relectures indépendantes sur une version saine connue ;
- démontré qu’il échoue sur la régression qu’il vise lorsqu’un cas reproductible existe ;
- défini sa classe, son coût, ses timeouts et ses conditions de nettoyage.

L’évaluateur protégé, les tests cachés, les oracles de référence et l’historique signé sont montés en lecture seule depuis une ref, un dépôt ou un store séparé. Le candidat peut modifier librement le code du projet, les tests visibles et le corpus visible, mais ne peut pas modifier les éléments protégés utilisés pour sa propre décision de promotion.

#### 15.4.8 Répétitions et décision statistique

Les tests déterministes doivent réussir à 100 %. Les tests non déterministes utilisent une évaluation séquentielle adaptative :

- P0 : 10 essais minimum, 20 maximum ;
- P1 : 7 essais minimum, 20 maximum ;
- P2 : 5 essais minimum, 12 maximum.

Le TPSR utilise une borne inférieure de Wilson à 95 %. Les différences v1/v2 utilisent un intervalle apparié à 95 % par bootstrap à graine enregistrée, ou une méthode exacte documentée si elle est plus adaptée.

L’évaluation s’arrête avant le maximum uniquement si l’intervalle permet déjà de conclure que le candidat est conforme, inférieur ou éliminé. Une exécution invalide pour cause d’évaluateur défaillant ou de matériel indisponible est marquée `invalid` et n’est pas transformée en échec du candidat.

#### 15.4.9 Fichiers de spécification et de sortie

Les spécifications versionnées minimales sont :

```text
evaluation/spec/capabilities.yaml
evaluation/spec/architecture.yaml
evaluation/spec/metrics.yaml
evaluation/spec/promotion.yaml
evaluation/spec/recovery.yaml
evaluation/spec/retention.yaml
evaluation/corpora/visible/<corpus_version>/manifest.yaml
evaluation/tasks/engineering/<corpus_version>/manifest.yaml
```

Les artefacts d’une évaluation sont écrits hors du workspace candidat sous :

```text
artifacts/evaluations/<evaluation_id>/
├── evaluation.json
├── manifest.json
├── gates.json
├── runtime.json
├── engineering.json
├── pareto.json
├── recovery.json
├── report.md
├── logs/
├── traces/
└── attempts/
```

`evaluation.json` est le résumé machine canonique et contient au minimum :

- `schema_version`, `evaluation_id`, `campaign_id` et timestamps ;
- commits v1, candidat, évaluateur et corpus ;
- environnement, matériel, firmware, noyau, driver, images, modèles et digests ;
- statut global et état de la machine de décision ;
- gates P0/P1/P2 et tolérances appliquées ;
- TPSR, intervalles de confiance et différences à la baseline ;
- métriques de Pareto avec unités ;
- résultats de la boucle d’ingénierie ;
- décision `reject`, `quarantine`, `pareto`, `promote` ou `rollback` ;
- raisons structurées, liens vers preuves et version du schéma.

Tous les fichiers JSON sont validés par JSON Schema. Les logs bruts ne sont jamais l’unique preuve d’une décision.

**Confidentialité et rétention :** les métriques et artefacts restent locaux par défaut ; toute télémétrie externe est désactivée sauf consentement explicite. Les secrets sont expurgés avant écriture et les prompts, sorties, traces, diffs et fichiers de travail sont classifiés. Chaque campagne déclare un quota et une politique de rétention distinguant les résumés durables des logs bruts temporaires. Tout nettoyage possède un dry-run et ne peut supprimer une preuve liée à une release active, une décision, un incident non clos ou un rollback encore supporté.

#### 15.4.10 Pipeline de promotion automatique

Le pipeline suit cet ordre :

1. analyse statique, format, types, secrets, dépendances, licences, SBOM et règles d’architecture ;
2. tests unitaires, propriétés, migrations et contrats d’adapters ;
3. protocoles modèles et parité sémantique v1/v2 ;
4. VM ou racine `rootless-dev` ;
5. VM `strict-prod` ;
6. campagne contrôlée sur la DGX avec coupe-circuits ;
7. faute injectée, endurance adaptée au risque et récupération ;
8. ombre ou canari lorsqu’un parcours existant est remplacé ;
9. mise à jour de la frontière de Pareto et promotion.

L’agent d’optimisation dispose d’une autonomie C+ dans le périmètre du projet. Il peut créer et modifier des branches, code, tests visibles, documentation, migrations et architecture ; ouvrir, mettre à jour et fusionner des PR ; abandonner une piste ; revenir à une version saine ; et lancer une autre stratégie.

Il ne peut pas :

- affaiblir un gate P0, modifier l’évaluateur protégé ou ses tests cachés ;
- supprimer un test pour faire disparaître une régression sans décision de corpus tracée ;
- falsifier ou réécrire les artefacts d’une évaluation terminée ;
- promouvoir un candidat dont les preuves sont incomplètes ;
- retirer une capacité v1 sans l’approbation humaine prévue en M12.

La fusion automatique vise la branche d’implémentation v2. Une release de production reste soumise aux règles d’update, d’ombre, de canari et de retrait du présent plan.

#### 15.4.11 Obligation de progression

Une campagne conserve une fenêtre glissante de cinq cycles. Un cycle est considéré comme progressif s’il réalise au moins une des actions suivantes sans introduire d’échec P0 :

- améliore une métrique de Pareto au-delà de son effet minimal significatif ;
- résout un échec ou une régression identifiée ;
- réduit une dette technique mesurée ;
- produit une preuve nouvelle qui invalide une hypothèse et entraîne un changement explicite de stratégie.

Après trois cycles consécutifs sans progrès, la boucle doit changer d’hypothèse, d’outil, de découpage ou de zone du code. Après cinq cycles sans progrès, elle restaure le dernier commit sain, archive la piste, crée ou met à jour le Bead correspondant et sélectionne un autre objectif. Répéter indéfiniment le même essai avec les mêmes paramètres est interdit.

#### 15.4.12 Exécution sur la DGX et restitution différée

Une campagne d’optimisation peut conserver entre ses cycles des conteneurs, caches, volumes, modèles et services dédiés afin d’éviter un nettoyage coûteux à chaque itération. Elle doit toutefois rendre chaque ressource traçable par `campaign_id`, propriétaire, date de création, politique de rétention et état désiré.

Avant la première mutation d’une campagne, la boucle enregistre :

```text
artifacts/campaigns/<campaign_id>/state-before.json
artifacts/campaigns/<campaign_id>/resources.json
artifacts/campaigns/<campaign_id>/restore-plan.json
```

La DGX n’est pas restaurée après chaque cycle. En revanche, une restitution peut être demandée à tout moment et devient obligatoire à la clôture définitive de la campagne. La commande cible est idempotente, supporte un dry-run et produit :

```text
artifacts/campaigns/<campaign_id>/restore-report.json
artifacts/campaigns/<campaign_id>/post-restore-doctor.json
```

La restitution :

- arrête les agents, jobs, processus et services propres à la campagne ;
- supprime ou archive selon le manifeste les conteneurs, réseaux, volumes et fichiers temporaires ;
- libère les ports, la mémoire GPU, la RAM et l’espace disque réservés ;
- retire les secrets et configurations temporaires ;
- restaure les services et configurations préexistants modifiés ;
- conserve uniquement les caches, images, modèles ou artefacts explicitement présents dans l’état initial ou marqués à conserver ;
- liste tout élément supprimé, restauré, conservé ou non résolu ;
- exécute un `post-restore doctor` prouvant la disponibilité de la DGX pour d’autres usages.

La capacité de restitution est un gate P0 architectural. Son exécution est testée avant la première promotion sur DGX, à chaque release et après toute modification du cycle de vie, du stockage, du réseau, des secrets ou du scheduler.

#### 15.4.13 Récupération et états de la boucle

La machine d’état minimale est :

```text
PROPOSED → EVALUATING → PARETO → PROMOTED
                    ↘ REJECTED
                    ↘ QUARANTINED → EVALUATING
PROMOTED → ROLLED_BACK
CAMPAIGN_ACTIVE → RESTORING → RESTORED
```

Règles de récupération :

- un échec P0 arrête la progression du candidat, préserve les preuves et déclenche le rollback vers la dernière version saine ;
- un échec de l’évaluateur invalide l’essai sans pénaliser le candidat ; l’évaluateur est restauré avant reprise ;
- un coupe-circuit DGX arrête les nouvelles admissions, draine ce qui peut l’être, capture l’état et restaure la plateforme si elle est instable ;
- un échec post-fusion entraîne un revert automatique et une nouvelle évaluation de la version restaurée ;
- aucune migration destructive ne peut être rejouée tant que sa récupération précédente n’est pas démontrée ;
- les artefacts d’un candidat rejeté sont conservés pour empêcher la répétition aveugle de la même stratégie.

La dernière version saine est définie par un commit, des digests, une version de données, un manifeste de ressources et une évaluation verte complète. Un simple commit Git ne constitue pas à lui seul un point de récupération.

### 15.5 Gouvernance de l’expérience utilisateur et décisions de conception

**DÉCISION :** la v2 ne reproduit pas les parcours de la v1 par défaut. La compatibilité fonctionnelle n’implique pas la conservation de son interface, de son organisation, de ses commandes ni de ses concepts visibles. La v1 est un inventaire de capacités et une baseline de non-régression, pas un modèle d’expérience utilisateur.

Le parcours utilisateur idéal n’est pas considéré comme connu au début de la refonte. Il est construit progressivement à partir des usages réels, des difficultés observées dans la v1, de prototypes, d’alternatives comparées, des directives du concepteur, des retours utilisateurs et des mesures d’utilisabilité.

#### 15.5.1 Principes de conception centrée utilisateur

Toute capacité visible doit :

- présenter d’abord l’objectif et le vocabulaire de l’utilisateur, pas l’infrastructure technique ;
- masquer Docker, OpenShell, les conteneurs, les ports internes, les noms de services et les fichiers internes dans les parcours ordinaires ;
- proposer un parcours principal simple, avec divulgation progressive des fonctions avancées ;
- utiliser des valeurs par défaut sûres, compréhensibles et réversibles ;
- rendre visibles l’état, l’attente, la progression, les conséquences d’une action et la prochaine étape possible ;
- permettre l’annulation, la reprise, le retry ou le retour arrière lorsqu’ils sont techniquement possibles ;
- utiliser une terminologie cohérente entre portail, CLI, API et interfaces natives ;
- fournir des erreurs actionnables, reliées au composant réellement en cause sans exposer inutilement sa complexité ;
- éviter toute étape manuelle qui n’apporte pas une décision réelle à l’utilisateur ;
- distinguer le parcours ordinaire du mode expert ou break-glass.

Une fonctionnalité ne doit pas être ajoutée au portail uniquement parce qu’un service ou une API existe. Inversement, une capacité nécessaire à un parcours peut disposer temporairement d’une surface simple et documentée avant son interface définitive.

#### 15.5.2 Détection des choix UX structurants

L’agent d’implémentation doit identifier explicitement les décisions ayant un effet durable sur l’expérience utilisateur. Une revue de conception est requise notamment lorsqu’un changement :

- modifie un parcours principal ;
- introduit un nouveau concept, terme, écran ou objet visible ;
- impose une étape manuelle supplémentaire ;
- expose un détail d’infrastructure ;
- détermine une valeur par défaut importante ;
- oppose simplicité, sécurité, performance, flexibilité ou compatibilité ;
- modifie les droits, la visibilité, la propriété ou la durée de conservation des données ;
- rend une action destructive, difficilement réversible ou coûteuse à corriger après déploiement ;
- retire ou remplace une capacité visible de la v1 ;
- laisse plusieurs alternatives non dominées sans critère objectif suffisant pour les départager.

Un choix local, facilement réversible, conforme à une directive active et sans effet sur un parcours principal peut être pris automatiquement et simplement enregistré.

#### 15.5.3 Alternatives soumises au concepteur

Lorsqu’une décision structurante ne possède pas de solution manifestement supérieure, l’agent ne choisit pas silencieusement. Il soumet au concepteur entre deux et quatre alternatives comprenant au minimum :

- le problème utilisateur et le contexte ;
- le ou les profils concernés ;
- le parcours proposé pour chaque alternative ;
- les avantages et inconvénients ;
- les conséquences techniques, opérationnelles et de sécurité ;
- le coût relatif d’implémentation et de maintenance ;
- la réversibilité et le coût d’un changement ultérieur ;
- les effets attendus sur les métriques produit/runtime et d’ingénierie ;
- une recommandation argumentée ;
- les hypothèses encore incertaines ;
- les conditions qui justifieraient un réexamen.

Lorsque la solution la plus complète risque de complexifier fortement l’usage, une alternative volontairement simple doit être proposée. Les alternatives peuvent être illustrées par une maquette, une séquence de commandes simulée, un prototype jetable ou un walkthrough documenté.

La demande de décision ne bloque pas les travaux indépendants. L’agent poursuit les tâches qui ne dépendent pas de l’arbitrage et peut prototyper plusieurs options sans les promouvoir en production.

Chaque demande de décision possède une condition ou une date de résolution. En l’absence de réponse, l’agent peut retenir temporairement l’alternative la plus simple, réversible et la moins exposée, avec le statut `experimental`, puis poursuivre. Cette règle ne permet jamais de rendre stable une décision `needs-design-review`, ni de trancher automatiquement une action destructive ou un changement P0 de sécurité, de droits ou de données.

#### 15.5.4 Directives du concepteur

Le concepteur peut définir des directives générales ou particulières, par exemple :

- privilégier la simplicité par rapport à l’exhaustivité ;
- éviter toute configuration avant le premier résultat utile ;
- privilégier une surface native, le portail ou la CLI pour un type de tâche ;
- ne pas exposer une fonction expérimentale aux utilisateurs ordinaires ;
- imposer une confirmation avant une action déterminée ;
- préserver un comportement jugé essentiel malgré une implémentation différente.

Les directives sont versionnées dans :

```text
docs/ux/directives.yaml
```

Chaque directive contient au minimum :

- `directive_id` ;
- auteur et date ;
- portée globale, persona, parcours, capacité ou composant ;
- texte normatif ;
- justification lorsqu’elle est connue ;
- statut `active`, `experimental`, `superseded` ou `revoked` ;
- directive remplacée, le cas échéant ;
- conditions ou date de réexamen ;
- liens vers les décisions et tests concernés.

Une directive active s’applique aux nouvelles décisions dans sa portée. Une directive n’est jamais supprimée de l’historique ; elle est remplacée ou révoquée avec justification.

#### 15.5.5 Registre des décisions UX

Les décisions d’expérience utilisateur sont conservées sous forme de `UX Decision Records` distincts des décisions purement techniques.

Structure cible :

```text
docs/ux/
├── principles.md
├── directives.yaml
├── open-questions.md
├── journeys/
├── prototypes/
└── decisions/
    └── UXDR-<number>-<title>.md
```

Chaque `UXDR` contient au minimum :

- identifiant, statut, auteur et date ;
- capacité et parcours concernés ;
- problème utilisateur ;
- profils concernés ;
- observations ou difficultés de la v1 à ne pas reproduire ;
- alternatives étudiées ;
- prototypes, mesures ou preuves disponibles ;
- décision retenue et justification ;
- conséquences connues ;
- directive applicable ;
- conditions de réexamen ;
- tests d’acceptation associés.

Les statuts autorisés sont :

```text
proposed
needs-design-review
accepted
experimental
superseded
rejected
```

Une décision `experimental` possède obligatoirement une date ou un événement de réévaluation. Une décision `needs-design-review` ne peut pas être promue silencieusement en comportement stable.

#### 15.5.6 Traçabilité de l’expérience utilisateur

Toute fonctionnalité visible doit être reliée à :

- un problème, besoin ou parcours utilisateur ;
- une directive active ou un `UXDR` ;
- un test d’acceptation ;
- les principaux états d’attente et d’erreur ;
- une procédure de récupération lorsqu’elle est nécessaire ;
- une métrique ou une observation permettant de juger son usage réel.

Les liens sont enregistrés dans le registre de capacités ou dans un manifeste UX versionné. Une fonctionnalité sans justification utilisateur explicite est mise en quarantaine de conception avant promotion.

#### 15.5.7 Prototypage et réévaluation

Pour les parcours structurants, la séquence privilégiée est :

```text
problème utilisateur
→ alternatives
→ prototype léger
→ revue du concepteur
→ walkthrough ou test utilisateur
→ décision tracée
→ implémentation
→ mesure
→ réévaluation éventuelle
```

Les prototypes peuvent être des maquettes, des interfaces non connectées, des commandes simulées ou des parcours documentés. Ils ne deviennent pas automatiquement des composants de production et peuvent être supprimés après archivage des enseignements utiles.

Une décision doit être réexaminée lorsqu’au moins une condition survient :

- son hypothèse principale est invalidée ;
- les utilisateurs échouent ou contournent régulièrement le parcours ;
- une nouvelle alternative réduit clairement la complexité ;
- une évolution amont change les possibilités d’intégration ;
- les métriques montrent une dégradation significative ;
- le concepteur modifie ou révoque une directive liée.

#### 15.5.8 Mesures d’utilisabilité

La boucle produit/runtime enregistre, lorsque le parcours le permet :

- le temps jusqu’au premier résultat utile ;
- le nombre d’étapes et de décisions demandées ;
- le nombre de concepts techniques exposés ;
- le taux de réussite sans assistance ;
- les erreurs, retries, abandons et retours arrière ;
- le recours à la documentation ou au support ;
- les interventions administrateur nécessaires ;
- les divergences de comportement entre portail, CLI, API et interfaces natives ;
- les points où l’utilisateur ne sait pas clairement ce qui se passe ou quoi faire ensuite.

Ces mesures servent à comparer des alternatives et à détecter les régressions. Elles ne remplacent pas le jugement qualitatif du concepteur ni les retours d’utilisateurs représentatifs.

#### 15.5.9 Gate de conception utilisateur

Une capacité visible ne peut être déclarée terminée que si :

- le problème utilisateur est décrit ;
- un parcours principal et ses états d’erreur sont documentés ;
- les choix structurants sont reliés à une directive ou à un `UXDR` ;
- les alternatives pertinentes ont été examinées lorsque nécessaire ;
- les valeurs par défaut sont justifiées ;
- les actions destructives et leurs conséquences sont explicites ;
- le parcours ordinaire ne nécessite aucune manipulation d’infrastructure non prévue ;
- les erreurs principales sont compréhensibles et actionnables ;
- les tests d’acceptation sont verts ;
- toute décision expérimentale possède une condition de réévaluation.

Ce gate ne doit pas multiplier artificiellement les validations humaines. Il empêche les choix d’interface implicites, opportunistes ou dictés uniquement par l’architecture de devenir des comportements durables sans arbitrage conscient.

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
| reproduction implicite de l’UX v1 | alternatives, prototypes, directives et UXDR |
| décisions d’interface non tracées | gate UX et registre versionné |

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
- la première version utilisable a franchi G3U avant l’élargissement aux capacités avancées ;
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
- les deux boucles d’optimisation produisent des artefacts conformes, une frontière de Pareto versionnée et des décisions reproductibles ;
- la non-infériorité P0/P1/P2 et les tolérances temporaires sont vérifiées automatiquement ;
- les campagnes d’optimisation peuvent être arrêtées administrativement sans redémarrage automatique et sans préempter les usages prioritaires ;
- les artefacts respectent la politique de confidentialité, de quota et de rétention ;
- chaque capacité visible possède un problème utilisateur, un parcours principal, des tests d’acceptation et une décision UX traçable ;
- les directives du concepteur et les `UXDR` sont versionnés, reliés à l’implémentation et réexaminés lorsque leurs hypothèses changent ;
- aucune interface de la v1 n’est reproduite par défaut sans justification explicite ;
- update, rollback et restauration ont été répétés ;
- une campagne d’optimisation peut restituer sur demande la DGX dans son état de référence et le `post-restore doctor` est vert ;
- une personne peut diagnostiquer, sauvegarder, restaurer et mettre à jour avec les runbooks ;
- l’administrateur approuve explicitement chaque retrait v1.
