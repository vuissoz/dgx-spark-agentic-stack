# DGX Spark Agentic Platform v2 — Plan stratégique de réécriture et de migration

## 0. Statut, méthode et gouvernance

Ce document est le plan actif de la v2. La v1 reste la référence fonctionnelle jusqu’à validation explicite de chaque domaine migré.

Référence v1 :

- branche : `archive/pre-v2-rewrite-2026-06-25`
- commit : `f76778e342d43fdafaa17e05ad887f6e9853aa7d`

La pull request reste en brouillon tant que les décisions bloquantes de la section 15 ne sont pas closes.

### 0.1 Vocabulaire de décision

Chaque affirmation structurante doit porter l’un des statuts suivants :

- **DÉCISION** : choix interne sous notre contrôle ;
- **CIBLE** : direction retenue, soumise à validation technique avant généralisation ;
- **HYPOTHÈSE** : capacité plausible mais non démontrée ;
- **BLOQUANT** : point à résoudre avant la phase qui en dépend.

Une hypothèse ne peut pas devenir implicitement une dépendance de production.

### 0.2 Règles de gouvernance

- `PLAN.md` définit le produit, les responsabilités, les contrats, la transition et les portes de validation ;
- Beads reste l’unique backlog opérationnel ;
- aucun identifiant Beads n’est inventé dans ce document ;
- chaque fonctionnalité v1 possède un propriétaire, un test de parité et une décision `conserver`, `remplacer`, `reconstruire` ou `retirer` ;
- `retirer` exige une décision humaine documentée ;
- toute dépendance externe est épinglée par version ou digest et entourée d’un adapter ;
- aucune bascule ne partage en écriture un même état entre v1 et v2 ;
- la restauration est testée avant la migration, pas après l’incident.

## 1. Contrat produit

La v2 doit rester exploitable par une petite équipe et administrable par une personne compétente sans devoir maintenir une constellation de microservices artisanaux.

### 1.1 Expérience attendue

- l’utilisateur choisit d’abord un agent, comme un collaborateur permanent ;
- le projet est un contexte facultatif de travail, pas le point d’entrée principal ;
- chaque agent ou application est accessible par CLI, portail web, ou les deux ;
- l’utilisateur ne manipule ni Docker, ni OpenShell, ni les ports internes ;
- les interfaces officielles utiles sont préservées : terminal, dashboard web, Desktop, éditeur ou messagerie ;
- les droits et l’état restent cohérents entre les surfaces d’un même agent ;
- la plateforme fonctionne localement et conserve un mode hors ligne explicite ;
- aucune mise à jour, suppression de données ou téléchargement lourd n’est silencieux.

### 1.2 Principes d’implémentation

- préserver les **capacités**, pas nécessairement les implémentations v1 ;
- préférer un composant amont mature à une réécriture locale lorsque son contrat est réellement couvert ;
- éviter les doubles sources de vérité ;
- commencer par un monolithe modulaire de contrôle, pas par une architecture distribuée ;
- livrer des parcours verticaux utilisables avant les fonctions avancées ;
- garder les adapters minces et testables ;
- faire de la compatibilité v1 une fonctionnalité transitoire explicite.

## 2. Registre obligatoire des capacités v1

La v2 doit générer et maintenir un registre de parité à partir de `agent --help`, des fichiers Compose, des répertoires persistants et des tests existants.

Le registre couvre au minimum :

### 2.1 Exploitation

- profil `rootless-dev` et validation `strict-prod` ;
- onboarding, prérequis, premier démarrage ;
- démarrage et arrêt par stack, service et cible ;
- `ls`, `status`, `ps`, logs et diagnostic ;
- `doctor` et suites de tests ;
- création, test et nettoyage de machine virtuelle de validation ;
- sauvegarde, liste et restauration ;
- nettoyage et oubli sélectif ;
- mise à jour, snapshots de release et rollback ;
- configuration réseau, tunnels et accès distants ;
- contrôle d’horloge GPU et diagnostics matériels.

### 2.2 Agents et applications

- Claude Code, Codex, OpenCode, KiloCode, VibeStral, Hermes, Pi, Goose ;
- OpenClaw, ses approvals, politiques, relay, pièces jointes et sandboxes ;
- OpenHands ;
- OpenWebUI ;
- ComfyUI et installation Flux ;
- Forgejo ;
- observabilité ;
- modules optionnels.

### 2.3 Modèles et données

- modes local, hybride et distant ;
- sélection Ollama, TensorRT-LLM ou fournisseur distant ;
- contexte et compaction ;
- benchmark, préchargement, chargement et déchargement des modèles ;
- surveillance de dérive Ollama ;
- liens et droits du store de modèles ;
- indexation RAG, suivi de tâche, configuration et backend lexical ;
- test de dépôt de bout en bout pour chaque agent.

### 2.4 Contrat de compatibilité CLI

**DÉCISION :** le binaire `agent` reste la façade utilisateur pendant toute la transition.

Chaque commande v1 reçoit :

- un identifiant de capacité stable ;
- une implémentation `v1`, `v2` ou `hybride` ;
- les mêmes codes de sortie utiles ;
- un format JSON stable lorsqu’il existe ;
- un test de compatibilité ;
- une date et une condition de retrait si elle devient obsolète.

Le routage v1/v2 est activable par utilisateur, agent, projet et capacité. Aucun script existant ne doit casser simplement parce qu’une fonction a migré.

## 3. Architecture générale

### 3.1 Plan de contrôle

**DÉCISION :** démarrer avec un monolithe modulaire :

- API FastAPI/Python ;
- worker séparé pour les tâches longues ;
- PostgreSQL ;
- frontend React ou Next.js ;
- REST versionné pour les commandes ;
- Server-Sent Events ou WebSocket pour les flux ;
- table d’outbox PostgreSQL pour les événements, sans ajouter un bus distribué au départ ;
- reconciler comparant état désiré et état observé ;
- identifiants de corrélation et clés d’idempotence.

Le plan de contrôle ne réimplémente pas les bases internes de Forgejo, OpenWebUI, OpenShell ou Qdrant. Il conserve leurs références, l’état désiré, les droits et une projection de leur état observé.

### 3.2 Zones de confiance

| Niveau | Exemples | Politique |
|---|---|---|
| Contrôle de confiance | portail, API, scheduler, broker de modèles, courtier de secrets | accès privilégié minimal, audit complet |
| Services gérés | PostgreSQL, Forgejo, Grafana, Qdrant, reverse proxy | Docker/Compose durci, réseau interne |
| Applications extensibles | OpenWebUI avec extensions, ComfyUI et custom nodes, JupyterLab | isolation renforcée, droits minimaux, aucune socket Docker |
| Exécution de code | agents, tâches OpenHands, outils autonomes | sandbox OpenShell cible |
| Administration de rupture | Portainer, shell hôte, OpenShell TUI direct | administrateur, réauthentification, audit, non visible par défaut |

Une application n’est pas considérée « de confiance » simplement parce qu’elle possède une interface web.

### 3.3 Déploiement

- Docker/Compose reste le socle des services gérés sur la DGX Spark ;
- OpenShell utilise initialement son pilote Docker pour les sandboxes ;
- Kubernetes n’est pas requis pour la v2 mono-machine ;
- MicroVM et Kubernetes restent des adapters futurs, sans modifier les contrats de haut niveau ;
- aucune fonctionnalité utilisateur ne dépend directement d’un nom de conteneur.

## 4. Modèle d’état et sources de vérité

La viabilité dépend d’une propriété claire de chaque donnée.

| Domaine | Source de vérité | Réplique ou projection |
|---|---|---|
| utilisateurs, rôles, projets, délégations | PostgreSQL du plan de contrôle | caches du portail |
| définitions d’agents et surfaces | PostgreSQL + manifestes versionnés | OpenShell/NemoClaw |
| état désiré d’un runtime | plan de contrôle | reconciler |
| état observé de sandbox | OpenShell | projection dans PostgreSQL |
| conversation et session native | stockage de l’agent concerné | index de recherche facultatif |
| dépôts et branches | Forgejo/Git | références dans le plan de contrôle |
| fichiers de projet | workspace persistant | sandbox montée ou synchronisée |
| secrets | SecretStore canonique | providers OpenShell ou fichiers temporaires de service |
| catalogue de modèles et politiques | plan de contrôle | broker de modèles |
| fichiers de modèles | store global sur disque | index du catalogue |
| sources documentaires | emplacement d’origine | catalogue et index RAG |
| embeddings et recherche vectorielle | Qdrant, régénérable | métadonnées dans PostgreSQL |
| logs | Loki ou stockage structuré retenu | liens et résumés dans PostgreSQL |
| métriques | Prometheus | tableaux de bord Grafana |
| sauvegardes | manifeste de sauvegarde | exports cohérents de chaque store |

**Invariant :** aucune donnée métier mutable ne possède deux sources de vérité actives.

## 5. Identité d’agent, projet et session

### 5.1 Objets distincts

- **AgentDefinition** : type d’agent, image, capacités, surfaces et politique par défaut ;
- **AgentIdentity** : collaborateur logique persistant visible par l’utilisateur ;
- **RuntimeContext** : exécution d’un agent pour un utilisateur et un contexte ;
- **Session** : conversation ou tâche native de l’agent ;
- **Project** : droits, workspace, secrets, modèles et collections associés.

### 5.2 Clé de runtime

**DÉCISION :** un contexte d’exécution est identifié par :

```text
utilisateur + identité d’agent + projet
```

Le contexte sans projet est un contexte personnel explicite.

OpenShell verrouille les politiques fichiers et processus à la création de la sandbox. Par conséquent, changer de projet ne remonte pas un nouveau workspace dans une sandbox existante. Le CLI et le portail se reconnectent à un autre `RuntimeContext`, créé ou repris.

```bash
agent codex
agent codex ARTANY
agent project SEGMENTATION-RTMRI
```

Le dernier exemple change le contexte actif, pas l’identité logique de Codex.

### 5.3 Persistance réelle

Trois niveaux sont distingués :

1. **reconnexion chaude** : la sandbox et le processus sont encore vivants ;
2. **reprise froide** : la sandbox est recréée depuis image, manifeste et politique épinglés, puis rattache son état persistant ;
3. **reprise native** : l’agent reprend une session grâce à sa propre fonction de reprise.

Un checkpoint mémoire générique n’est pas supposé. Il reste une capacité facultative par adapter. Les tâches non reprenables sont marquées comme telles et ne sont pas préemptées de force hors décision administrateur.

### 5.4 Séparation des données

Chaque contexte dispose de :

- workspace projet persistant ;
- état agent-projet persistant ;
- scratch runtime éphémère ;
- préférences utilisateur-agent limitées et contrôlées ;
- références de secrets, jamais les secrets eux-mêmes.

Un HOME mutable partagé entre projets est interdit par défaut afin d’éviter les fuites de contexte.

## 6. Broker de modèles et inférence

### 6.1 Contrat, pas implémentation imposée

**DÉCISION :** la capacité s’appelle `ModelBroker`. `ollama-gate` est l’adapter de compatibilité v1, pas une implémentation éternelle imposée.

Le choix entre évolution du gate actuel et adoption d’un gateway existant est décidé après un benchmark de contrat.

### 6.2 Responsabilités du ModelBroker

- API OpenAI nécessaire aux clients ;
- API Ollama nécessaire à la compatibilité ;
- embeddings ;
- catalogue et alias de modèles ;
- routage Ollama, TensorRT-LLM, vLLM ou fournisseur distant autorisé ;
- disponibilité et santé des backends ;
- streaming homogène ;
- identité utilisateur/agent/projet/tâche vérifiée ;
- quotas, priorité, attribution d’usage et coûts ;
- décision explicite de fallback ;
- admission avec le scheduler avant chargement ou bascule GPU.

### 6.3 Responsabilités d’OpenShell

OpenShell gère pour les agents :

- politique réseau du sandbox ;
- autorisation d’atteindre le ModelBroker ;
- injection d’un jeton court ou d’un placeholder de credential ;
- blocage des accès directs aux backends modèles ;
- journalisation des autorisations et refus réseau.

OpenShell ne possède pas le catalogue global, les quotas projet, le scheduler GPU ni le choix dynamique multi-backend de la plateforme.

### 6.4 Usage de `inference.local`

OpenShell configure actuellement `inference.local` au niveau de la gateway avec un provider et un modèle appliqués aux sandboxes. Il peut réécrire le modèle demandé.

**DÉCISION :**

- utiliser `inference.local` seulement pour un profil volontairement à modèle fixe ;
- pour le choix dynamique, autoriser le sandbox à joindre le ModelBroker interne avec un jeton court injecté par OpenShell ;
- interdire l’accès direct à Ollama, TensorRT-LLM, vLLM et fournisseurs distants ;
- tester que le modèle demandé et l’identité arrivent intacts au ModelBroker.

### 6.5 Jeton d’identité

Le plan de contrôle émet un jeton court signé contenant :

- utilisateur ;
- agent ;
- projet ;
- tâche ou session ;
- scopes modèles ;
- expiration ;
- identifiant de corrélation.

Le ModelBroker ne fait jamais confiance à des en-têtes d’identité librement définis par le client.

## 7. OpenShell et NemoClaw

### 7.1 Positionnement

**CIBLE :** OpenShell est le runtime principal des agents.

**DÉCISION :** OpenShell reste derrière `AgentRuntimeAdapter`. Le plan de contrôle est la frontière multi-utilisateur et le seul client normal de la gateway OpenShell. Les utilisateurs ne reçoivent pas un accès direct à son API.

La topologie initiale visée est une gateway interne par hôte DGX. Une gateway séparée par domaine de sécurité reste possible si les tests montrent que l’isolation logique est insuffisante.

### 7.2 Limites à ne pas masquer

- OpenShell est encore annoncé en alpha et en mode initial mono-utilisateur ;
- les politiques fichiers et processus sont statiques à la création ;
- le scheduler et les réservations globales ne sont pas fournis par OpenShell ;
- les limites CPU et mémoire sont appliquées par le pilote, mais la planification globale reste notre responsabilité ;
- le GPU et ses API évoluent encore ;
- aucune fonction générique de checkpoint mémoire n’est considérée acquise ;
- les upgrades alpha peuvent exiger de recréer les sandboxes.

Ces limites sont intégrées dans les contrats et les tests, pas reléguées dans une note.

### 7.3 AgentRuntimeAdapter

Le contrat couvre :

- capacités réellement disponibles ;
- création, connexion, état, arrêt et suppression ;
- exécution interactive et non interactive ;
- service web exposé par forwarding contrôlé ;
- création avec image, politique, providers, ressources et labels ;
- export du manifeste reproductible ;
- collecte d’état et logs ;
- suppression des credentials ;
- reprise chaude et froide ;
- checkpoint uniquement si supporté.

### 7.4 NemoClaw

**CIBLE :**

- NemoClaw est le chemin privilégié pour OpenClaw ;
- NemoClaw est évalué en priorité pour Hermes.

Hermes est officiellement indiqué comme testé avec limitations et sans affirmation de parité de production avec OpenClaw. La bascule Hermes exige donc un test complet du dashboard, des sessions, de la mémoire, des outils, des modèles et des messageries.

Si NemoClaw ne préserve pas le contrat Hermes, la solution n’est ni de perdre des fonctions ni de contourner OpenShell : un blueprint Hermes spécifique est maintenu derrière le même adapter.

## 8. Applications, portail et surfaces

### 8.1 Portail agent-first

Accueil : annuaire des agents visibles par l’utilisateur.

Page agent :

- identité, rôle et état ;
- projet actif ;
- ouvrir/reprendre une session ;
- changer de contexte ;
- ouvrir l’interface web native si elle existe ;
- commande CLI équivalente ;
- tâches, approvals, usage et incidents récents.

Sections séparées :

- Applications ;
- Projets ;
- Modèles ;
- Ressources ;
- Données et RAG ;
- Système et administration.

### 8.2 Surfaces natives

- Hermes Dashboard est exposé par le mécanisme de service OpenShell ou un reverse proxy validé ;
- Hermes Desktop se connecte au même backend si le flux distant est officiellement supporté et testé ;
- DGX Dashboard et JupyterLab sont lancés par un chemin supporté : lien, tunnel ou proxy validé ;
- aucune intégration par iframe ou réécriture de sous-chemin n’est supposée fonctionner ;
- Grafana, Forgejo, OpenWebUI, OpenHands et ComfyUI utilisent leurs interfaces natives derrière authentification et droits.

### 8.3 Applications exécutant du code

- les tâches OpenHands s’exécutent dans OpenShell ou un runtime équivalent validé ;
- ComfyUI avec custom nodes reçoit une politique et un réseau restrictifs ;
- JupyterLab n’est pas assimilé à une simple page de dashboard ;
- Portainer reste une fonction de rupture, administrateur uniquement, désactivée par défaut.

## 9. Secrets

**DÉCISION :** un seul `SecretStore` canonique.

Le SecretStore assure :

- chiffrement au repos ;
- séparation utilisateur, équipe et projet ;
- rotation et expiration ;
- journalisation des accès ;
- absence de valeur secrète dans PostgreSQL, logs, RAG ou mémoire agent.

Les providers OpenShell sont un mécanisme de livraison et de rotation dans les sandboxes, pas une seconde source de vérité. Les services Docker reçoivent des fichiers temporaires ou secrets montés en lecture seule.

Le choix technique du SecretStore est une décision bloquante : solution locale chiffrée simple ou produit dédié, évalués selon restauration, rotation, mode hors ligne et charge d’exploitation.

## 10. Scheduler et ressources

### 10.1 Responsabilité

Le scheduler du plan de contrôle possède :

- file d’attente et priorité ;
- réservations ;
- quotas utilisateurs et projets ;
- admission CPU, mémoire, GPU et stockage ;
- politiques normal, burst et exclusif ;
- drain et délais de grâce ;
- coordination avec le ModelBroker et les services GPU.

OpenShell applique les limites demandées au sandbox mais ne remplace pas ce scheduler.

### 10.2 Stratégie progressive

1. admission simple et limites fixes ;
2. métriques et refus explicites ;
3. priorités et files ;
4. réservations et calendrier ;
5. préemption coopérative ;
6. optimisation adaptative.

Les fonctions avancées ne bloquent pas le premier parcours Codex, mais aucune promesse de préemption n’est faite avant la reprise réelle des tâches.

## 11. Catalogue, mémoire et RAG

- les fichiers source restent la vérité ;
- le catalogue, les droits et la provenance sont dans PostgreSQL ;
- Qdrant contient un index régénérable ;
- les contrôles d’accès sont appliqués côté serveur, jamais seulement dans l’interface ;
- les collections sensibles sont séparées ou filtrées par un mécanisme testé contre les fuites ;
- la première indexation requiert une autorisation humaine ;
- la réindexation est idempotente ;
- chaque réponse RAG expose sources et passages ;
- la mémoire globale de l’agent et la mémoire projet sont distinctes ;
- aucune conversation privée ne devient automatiquement une source commune.

## 12. Stratégie de migration

### 12.1 Pattern d’étranglement

La commande `agent` reste la façade. Chaque capacité est routée vers v1 ou v2 par feature flag.

La migration se fait par **parcours vertical** :

```text
utilisateur → CLI/portail → identité → projet → runtime → modèle → workspace → logs → sauvegarde
```

Un parcours n’est pas déclaré migré si un de ces maillons dépend encore d’un contournement manuel.

### 12.2 Règles de données

- v1 et v2 utilisent des racines distinctes ;
- les modèles peuvent être partagés en lecture seule pendant l’ombre ;
- les écritures concurrentes dans un même store sont interdites ;
- les importeurs sont versionnés, idempotents, exécutables en dry-run et produisent un rapport ;
- chaque domaine possède un moment de gel, un import final, un test et un rollback ;
- la double écriture est interdite sauf journal append-only explicitement conçu pour cela.

### 12.3 Sauvegarde

Le snapshot `rsync` v1 est conservé comme filet de migration mais ne devient pas la stratégie finale unique.

La v2 réalise des exports cohérents :

- PostgreSQL par outil natif ;
- Forgejo par procédure officielle ;
- Qdrant par snapshot ;
- états applicatifs selon leur procédure ;
- workspaces par snapshot fichier ;
- secrets dans une archive chiffrée séparée ;
- manifeste avec versions, digests, empreintes et dépendances.

La restauration complète est répétée dans une racine isolée.

## 13. Phases de livraison

### M0 — Preuves et gel v1

- tag, archive, inventaire des commandes et services ;
- baseline de performance et ressources ;
- sauvegarde et restauration complète ;
- registre de parité initial.

**G0 :** v1 restaurée et toutes les capacités visibles dans le registre.

### M1 — Contrats produit et architecture

- contrats CLI, API, données, agents, modèles et secrets ;
- matrice des sources de vérité ;
- modèle utilisateur-agent-projet-runtime ;
- classification des applications ;
- ADR principales.

**G1 :** aucune responsabilité dupliquée ou sans propriétaire.

### M2 — Spikes bloquants sur la DGX

- OpenShell Docker/ARM64, auth interne et labels d’ownership ;
- limites CPU, mémoire et GPU ;
- contexte par projet et reprise froide ;
- service forwarding pour Hermes Dashboard ;
- NemoClaw OpenClaw et Hermes ;
- ModelBroker dynamique sans conflit avec `inference.local` ;
- accès DGX Dashboard et JupyterLab ;
- SecretStore et restauration.

**G2 :** chaque hypothèse reçoit `validée`, `remplacée` ou `abandonnée`, avec preuve reproductible.

### M3 — Walking skeleton

Un parcours minimal utilisable :

- un administrateur et un utilisateur ;
- Codex ;
- contexte personnel et un projet ;
- CLI `agent codex [projet]` ;
- portail agent-first minimal ;
- OpenShell via adapter ;
- ModelBroker via adapter de compatibilité ;
- workspace, logs, arrêt et reprise froide ;
- sauvegarde du parcours.

**G3 :** parcours complet sans commande Docker/OpenShell manuelle.

### M4 — Fondation de production

- authentification, rôles et délégations ;
- reconciler et idempotence ;
- SecretStore ;
- audit ;
- observabilité ;
- admission simple ;
- installation, désinstallation et upgrade épinglé.

**G4 :** séparation utilisateurs/projets et restauration validées.

### M5 — Plan modèle

- contrat ModelBroker complet ;
- décision évoluer/remplacer `ollama-gate` ;
- Ollama, TensorRT-LLM et fournisseur distant autorisé ;
- embeddings, quotas, identité, streaming et admission GPU ;
- migration des commandes modèle v1.

**G5 :** aucun accès direct aux backends et parité des commandes modèle.

### M6 — Agents de code

- Claude Code, Codex, OpenCode ;
- KiloCode, VibeStral ;
- Pi et Goose ;
- politique, image, reprise et interfaces par agent ;
- test dépôt réel et isolation inter-projet.

**G6 :** chaque agent obligatoire passe son contrat vertical et ses tests négatifs.

### M7 — Hermes, OpenClaw et OpenHands

- OpenClaw via NemoClaw si parité ;
- Hermes via NemoClaw ou blueprint spécifique ;
- dashboards, Desktop et messageries retenues ;
- approvals, relay, pièces jointes, mémoire et outils ;
- exécution OpenHands isolée.

**G7 :** aucune régression des fonctions v1 et aucune élévation implicite.

### M8 — Applications et portail complet

- OpenWebUI, ComfyUI, Forgejo, Grafana ;
- DGX Dashboard et JupyterLab ;
- catalogue d’applications et droits ;
- commandes de gestion CLI correspondantes.

**G8 :** toutes les applications accessibles sans port interne et selon leur niveau de confiance.

### M9 — RAG, catalogue et données

- import des sources v1 ;
- ACL, collections, citations et réindexation ;
- mémoire globale/projet ;
- tests de fuite et restauration.

**G9 :** aucune fuite inter-projet et index entièrement régénérable.

### M10 — Scheduler avancé et collaboration

- files, priorités, réservations et calendrier ;
- Mattermost et Dify seulement après stabilisation ;
- bots distincts et boucles contrôlées.

**G10 :** charge et conflits maîtrisés sans casser l’interactif.

### M11 — Ombre, canari et bascule par domaine

- tâches miroir non destructives ;
- canaris par utilisateur, agent, projet et capacité ;
- comparaison résultats, performance, coûts et incidents ;
- gel et import final par domaine ;
- rollback chronométré.

**G11 :** deux cycles représentatifs sans perte et décision humaine de bascule.

### M12 — Retrait contrôlé

- retrait des routes v1 validées ;
- conservation archives et dernière sauvegarde ;
- retrait du fallback Docker agent seulement lorsqu’il n’est plus utilisé ;
- nettoyage proposé, jamais automatique.

## 14. Tests et critères de qualité

### 14.1 Contrats

- CLI v1/v2 ;
- API versionnée ;
- adapters runtime, modèle, secrets et applications ;
- import/export ;
- compatibilité des versions épinglées.

### 14.2 Sécurité

- lecture et écriture fichiers refusées ;
- fuite inter-projet ;
- réseau, méthodes et chemins refusés ;
- secret absent des logs, environnements persistants et sorties ;
- accès direct aux backends modèles refusé ;
- séparation des rôles ;
- actions administrateur réauthentifiées.

### 14.3 Résilience

- redémarrage API, worker, OpenShell et backend modèle ;
- sandbox perdue puis recréée ;
- modèle indisponible ;
- disque presque plein ;
- migration interrompue ;
- rollback code et rollback données distincts ;
- restauration sur racine vierge.

### 14.4 Utilisabilité

- premier démarrage guidé ;
- état vide compréhensible ;
- `agent codex` sans projet ;
- changement de projet ;
- reprise après déconnexion ;
- ouverture des dashboards ;
- erreurs actionnables ;
- aucune terminologie d’infrastructure imposée à l’utilisateur.

### 14.5 Performance

Les seuils sont établis à partir de la baseline v1 :

- temps d’ouverture chaud et froid d’un agent ;
- latence ajoutée par les proxies ;
- débit et streaming modèle ;
- consommation au repos ;
- temps de sauvegarde et restauration ;
- comportement sous concurrence.

Aucune régression importante n’est acceptée sans justification documentée.

## 15. Registre des risques et décisions bloquantes

| Risque | Conséquence | Traitement obligatoire |
|---|---|---|
| OpenShell alpha et mode initial mono-utilisateur | isolation ou upgrade fragile | gateway interne, adapter, pinning, spike multi-utilisateur |
| `inference.local` global et modèle réécrit | perte du routage dynamique | ModelBroker direct autorisé par politique |
| politiques fichiers statiques | changement de projet dangereux | un RuntimeContext par projet |
| absence de checkpoint générique | préemption destructrice | reprise chaude/froide/native séparées |
| scheduler absent d’OpenShell | surallocation | scheduler du plan de contrôle |
| GPU et API ressources en évolution | incompatibilité DGX | tests épinglés et capability discovery |
| Hermes NemoClaw avec limitations | perte dashboard/mémoire/outils | parité complète ou blueprint spécifique |
| double emploi `ollama-gate`/OpenShell | complexité et incohérence | contrat ModelBroker et décision build/adopt |
| applications web exécutant du code | compromission hôte | classification et runtime restreint |
| proxy des dashboards supposé | interface cassée ou auth contournée | utiliser seulement un chemin officiellement validé |
| sauvegarde fichier non cohérente | restauration invalide | exports natifs orchestrés |
| réécriture trop large avant validation | projet interminable | walking skeleton puis vertical slices |
| trop de composants optionnels | coût d’exploitation | baseline minimale, modules désactivés par défaut |

## 16. Mise à jour et exploitation

- versions et digests épinglés ;
- manifeste de compatibilité entre plateforme, OpenShell, NemoClaw, agents et backends ;
- aucune mise à jour automatique de production ;
- validation dans une racine ou machine de test ;
- migrations de base sauvegardées avant exécution ;
- rollback code par digest ;
- rollback données par restauration, sans supposer des migrations descendantes fiables ;
- génération de SBOM, vérification de provenance et scan de vulnérabilités ;
- mode break-glass documenté ;
- runbooks d’incident et de capacité.

## 17. Définition de terminé

La v2 est viable et la v1 peut être retirée seulement si :

- 100 % des capacités v1 ont une décision et un test ;
- les parcours principaux CLI et portail sont utilisables sans connaissance de l’infrastructure ;
- les sources de vérité sont uniques et restaurables ;
- la séparation utilisateur/projet est démontrée ;
- le ModelBroker n’entre pas en conflit avec OpenShell ;
- les agents obligatoires ont un runtime reproductible et une reprise documentée ;
- les applications exécutant du code sont isolées ;
- l’upgrade et le rollback ont été répétés ;
- les sauvegardes ont été restaurées sur une racine vierge ;
- les dépendances alpha sont épinglées et remplaçables derrière des adapters ;
- les ressources au repos et en charge restent compatibles avec la DGX Spark ;
- la documentation utilisateur, opérateur, développeur et sécurité correspond au système réel ;
- une seule personne peut diagnostiquer, sauvegarder, restaurer et mettre à jour la plateforme à l’aide des runbooks ;
- l’administrateur approuve explicitement chaque retrait de domaine v1.
