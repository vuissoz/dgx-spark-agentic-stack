# DGX Spark Agentic Platform v2 — Plan canonique de refonte et de migration

## 0. Statut, portée et source de vérité

Ce document remplace intégralement l’ancienne roadmap A→L comme **plan actif** de la plateforme. L’ancien plan, l’état du code et la documentation v1 restent consultables dans :

- branche d’archive : `archive/pre-v2-rewrite-2026-06-25`
- commit de référence : `f76778e342d43fdafaa17e05ad887f6e9853aa7d`

La pull request de refonte reste en brouillon tant que ce plan n’a pas été relu et accepté. Aucune implémentation v2 ne doit commencer à partir d’un paragraphe ambigu.

Règles de gouvernance :

- `PLAN.md` décrit l’architecture, les invariants, les phases et les portes de validation ;
- **Beads reste l’unique backlog opérationnel** : aucun travail ne commence sans identifiant Beads réel, dépendances et critères d’acceptation ;
- aucun identifiant Beads n’est inventé dans ce document ;
- chaque phase produit des artefacts concrets, de la documentation et des tests binaires ;
- une phase ne se ferme pas tant que sa porte de validation n’est pas verte ;
- la migration est réversible jusqu’à une décision humaine explicite de retrait de la v1.

## 1. But de la refonte

Transformer la stack actuelle, fonctionnelle mais difficile à exploiter, en une plateforme locale multi-utilisateur et multi-agent :

- agréable à installer, utiliser, mettre à jour et désinstaller ;
- adaptée à une DGX Spark de développement, sans en faire une appliance dédiée ;
- accessible sur le réseau local avec authentification obligatoire ;
- utilisable hors Internet pour toutes les fonctions locales ;
- capable d’exécuter environ 30 identités d’agents persistantes, mais des runtimes dormants à la demande ;
- capable d’attribuer, négocier, réserver et reprendre les ressources CPU, mémoire unifiée, GPU et stockage ;
- conservant les fonctionnalités et les agents déjà établis ;
- extensible vers OpenShell puis Kubernetes sans imposer ces technologies au chemin mono-DGX ;
- documentée comme un produit cohérent, et non comme une collection de scripts Compose.

La refonte n’est pas une réécriture « big bang ». Elle se fait en parallèle de la v1, par import contrôlé, tests de parité, fonctionnement en ombre, canari, bascule et rollback.

## 2. Critères de réussite globaux

La v2 ne peut remplacer la v1 que si les conditions suivantes sont toutes vraies :

1. le snapshot de la v1 a été restauré et validé au moins une fois ;
2. chaque fonction v1 conservée possède un test v2 équivalent ou supérieur ;
3. chaque agent existant possède un statut explicite, un adapter, un chemin de migration et un test de parité ;
4. le portail, le CLI `agent` et la configuration déclarative utilisent la même API et la même base d’état ;
5. aucun agent, adapter, gateway, Dify ou service UI ne monte le socket Docker ;
6. `ollama-gate` est le seul chemin d’accès aux modèles pour les utilisateurs et les agents ;
7. les modèles existants sont réutilisés sans copie ni retéléchargement inutile ;
8. les workspaces, dépôts, états importants, secrets autorisés, mémoires et catalogues ont été migrés ou explicitement classés comme régénérables ;
9. la sauvegarde et la restauration v2 sont testées ;
10. le mode LAN, le mode hors ligne et le rollback de bascule sont validés ;
11. la documentation utilisateur, opérateur, développeur, sécurité et migration correspond à la version réellement déployée ;
12. l’administrateur approuve explicitement la bascule.

## 3. Préservation de l’état actuel avant migration

### 3.1 Sauvegarde du code et de la documentation

Déjà matérialisée :

- branche `archive/pre-v2-rewrite-2026-06-25` pointant sur l’état de `master` avant la réécriture du plan ;
- l’ancien `PLAN.md`, les README, `AGENTS.md`, Compose, scripts, tests, ADR et runbooks y restent consultables.

Avant toute suppression ou déplacement ultérieur :

- créer un tag ou une release Git immuable `v1-pre-v2-migration` sur le commit de référence ;
- exporter la liste des branches, pull requests, issues/Beads et versions d’images ;
- produire un manifeste SHA-256 de tous les fichiers versionnés ;
- vérifier qu’un clone de l’archive permet toujours d’exécuter les tests v1.

### 3.2 Sauvegarde du runtime v1

Aucune migration en place n’est autorisée. Deux racines distinctes sont utilisées pendant toute la transition :

- `V1_ROOT` : racine actuelle de `rootless-dev` ou `strict-prod` ;
- `SPARK_ROOT` : nouvelle racine v2.

Le snapshot v1 doit inclure :

- Compose effectif, variables runtime non secrètes, profils et versions ;
- images et digests réellement déployés ;
- bases et volumes applicatifs ;
- workspaces et dépôts Git ;
- états des agents, conversations importantes et files d’approbation ;
- Forgejo, OpenWebUI, OpenHands, OpenClaw, RAG et observabilité ;
- configuration réseau et règles d’egress ;
- secrets dans une archive chiffrée séparée ;
- rapport de santé et résultats de tests de référence.

Les modèles et gros jeux de données ne sont pas recopiés. Le snapshot contient pour eux :

- chemin physique ;
- taille ;
- format ;
- empreinte lorsque calculable ;
- source et version ;
- procédure de récupération ;
- droits attendus.

### 3.3 Test obligatoire de restauration v1

Avant la première ligne de code v2 :

- restaurer le snapshot dans une racine isolée ;
- démarrer la stack v1 restaurée sans toucher à l’instance active ;
- exécuter `doctor`, les tests critiques, un appel modèle, un agent CLI, OpenWebUI, OpenHands, OpenClaw, ComfyUI, RAG et Forgejo ;
- documenter le temps de restauration et les écarts ;
- interdire la suite si la restauration n’est pas reproductible.

## 4. Inventaire canonique des fonctions à préserver

### 4.1 Plan modèle et services fondamentaux

| Fonction v1 | Exigence v2 |
|---|---|
| Ollama partagé | conservé, interne, non exposé directement |
| `ollama-gate` | conservé et étendu en passerelle OpenAI + Ollama, identités, quotas, priorités et audit |
| `gate-mcp` | conservé comme capacité d’outils contrôlée ou absorbé par un service d’outils équivalent, sans perte fonctionnelle |
| TensorRT-LLM optionnel | conservé comme backend interne optionnel, un seul modèle actif par défaut sur DGX Spark |
| routage modèles local/distant | conservé, explicite, auditable et sans fallback silencieux |
| contexte et compaction | conservés par profil de modèle et runtime |
| Unbound + proxy d’egress | remplacés ou conservés par une politique réseau v2 testée |
| fonctionnement hors ligne | obligatoire |
| benchmark et warm-up modèles | conservés dans les diagnostics et tests de capacité |
| stockage global des modèles | conservé, dédupliqué, sans suppression automatique |

### 4.2 Agents et runtimes à préserver

Aucun agent existant ne peut disparaître derrière « autres agents ».

| Agent/runtime v1 | Type cible | État à préserver | Phase de migration | Condition de parité |
|---|---|---|---|---|
| Claude Code | adapter CLI générique | workspace, config utile, secrets délégués, historique de tâches utile | vague CLI 1 | dépôt modifié, tests exécutés, reprise et audit |
| Codex | adapter CLI générique | workspace, config, contexte, dépôts et branches | vague CLI 1 | même scénario de bout en bout que v1, plus annulation/checkpoint |
| OpenCode | adapter CLI générique | workspace, config et état persistant | vague CLI 2 | scénario dépôt complet et accès modèle via gate |
| KiloCode | adapter CLI générique | workspace et configuration | vague CLI 2 | démarrage, tâche, outils, reprise et arrêt propres |
| Mistral Vibe / VibeStral | adapter CLI générique | workspace, configuration, modèle et contexte | vague CLI 2 | analyse/modification de dépôt, test et publication |
| Hermes | adapter CLI spécialisé puis générique | `HERMES_HOME`, mémoire utile, sessions et workspace | vague CLI 2 | session persistante, annulation, reprise et modèle via gate |
| Pi Coding Agent | adapter CLI générique optionnel | workspace et configuration | vague CLI 3 | même contrat agent, profil optionnel |
| Goose | adapter CLI générique optionnel | sessions, workspace et limite de contexte | vague CLI 3 | même contrat agent, compaction cohérente |
| OpenClaw | adapter service/API | config immuable, overlay, état, approvals, relay, pièces jointes, skills, workspaces | vague services | API authentifiée, sandbox, approvals et reprise |
| OpenHands | adapter service/API + UI | conversations utiles, config, workspace, état | vague services | UI, tâche code, gate, persistance et absence de socket Docker |
| agents personnalisés futurs | manifeste déclaratif | identité, rôle, permissions, runtime, image, outils | après contrat stable | validation automatique du manifeste et sandbox |

### 4.3 UIs, outils et données

| Composant v1 | Exigence v2 |
|---|---|
| OpenWebUI | conservé, accessible par portail, modèles uniquement via gate |
| ComfyUI | conservé, profil GPU planifiable, modèles globaux, sorties cataloguées |
| Forgejo | conservé, comptes/identités agents, branches protégées, dépôts et hooks migrés |
| Portainer | optionnel ; ne doit pas devenir un contournement du plan de contrôle |
| Prometheus/Grafana/Loki/exporters | conservés ou remplacés par équivalents couvrant les mêmes métriques |
| Qdrant/RAG retriever/worker | migrés vers le catalogue et le RAG gouverné |
| OpenSearch lexical | optionnel, conservé si utile et compatible avec les ressources |
| MCP catalog | conservé comme module optionnel gouverné |
| workspaces `shared-ro/shared-rw` | remplacés par des montages déclaratifs et autorisés, avec compatibilité de migration |
| update/rollback par digest | obligatoire en v2 |
| backup/restore | obligatoire et testé |
| `doctor`, onboarding, cleanup, forget, logs, status | conservés derrière le point d’entrée unique `agent` et complétés par le portail, avec parité fonctionnelle |

## 5. Architecture cible v2

### 5.1 Principe d’accès utilisateur : CLI ou portail

Chaque agent, application ou fonction opérateur doit posséder un **point d’accès utilisateur explicite et testé** :

- soit directement dans un terminal par une commande du CLI `agent` ;
- soit dans le navigateur depuis l’interface du portail ;
- soit par les deux lorsque cela apporte une vraie valeur.

Aucun utilisateur ne doit connaître un port, un nom de conteneur, une commande Docker, un fichier Compose ou un identifiant interne pour accéder à un composant.

Le point d’entrée dépend de la nature du composant :

- un agent CLI se rejoint naturellement dans un terminal ;
- une application graphique s’ouvre naturellement depuis le portail ;
- une fonction d’administration importante est disponible dans le portail et, lorsque pertinent, par le CLI `agent` pour l’automatisation.

#### 5.1.1 Accès direct aux agents CLI

L’expérience v1 est conservée comme contrat utilisateur :

```bash
agent codex
agent codex ARTANY
agent claude ARTANY
agent hermes SEGMENTATION-RTMRI
```

`agent codex` ouvre ou reprend directement la session persistante de Codex. Le projet est facultatif et désigne seulement le workspace actif de cet agent. L’utilisateur choisit donc **à qui il parle**, puis éventuellement le dossier sur lequel cet agent travaille.

Sans projet explicite, le dernier projet utilisé par cet utilisateur avec cet agent est repris. Si aucun projet n’existe, l’agent s’ouvre sans projet et peut discuter ; il demande un projet seulement lorsqu’une opération sur des fichiers l’exige.

Le changement de projet s’effectue depuis l’agent ou par le CLI, sans retourner à un portail de sélection et sans changer d’agent. La v2 doit définir une commande simple et cohérente, par exemple :

```bash
agent project SEGMENTATION-RTMRI
```

Le changement remplace automatiquement le workspace, les permissions, les collections RAG, les quotas et les références de secrets applicables. La mémoire générale de l’agent reste disponible, mais aucune information confidentielle d’un projet ne traverse vers un autre projet.

Les détails techniques — conteneur, `tmux`, runtime, réseau, reprise de session — sont masqués. Une déconnexion SSH ne détruit pas le travail en cours.

#### 5.1.2 Accès aux applications web

Le portail est le point d’entrée web unique. Il présente uniquement les applications et fonctions autorisées à l’utilisateur et ouvre, si nécessaire, l’application dans un nouvel onglet derrière le reverse proxy authentifié.

L’utilisateur ne saisit jamais directement l’adresse ou le port d’OpenWebUI, OpenHands, ComfyUI, Forgejo, Grafana, Mattermost ou Dify.

Le portail gère également les fonctions transversales :

- état des agents et tâches ;
- approbations ;
- calendrier et ressources ;
- modèles ;
- utilisateurs et droits ;
- projets ;
- catalogue et RAG ;
- quotas et coûts ;
- sauvegardes, mises à jour et rollback ;
- journaux, alertes et rapports.

Le portail n’est pas un passage obligatoire pour utiliser un agent CLI comme Codex.

#### 5.1.3 Matrice d’accès obligatoire

| Composant | Accès terminal par `agent` | Accès web depuis le portail | Accès principal |
|---|---:|---:|---|
| Claude Code | oui | facultatif, via terminal web ultérieur | terminal |
| Codex | oui | facultatif, via terminal web ultérieur | terminal |
| OpenCode | oui | facultatif | terminal |
| KiloCode | oui | facultatif | terminal |
| VibeStral | oui | facultatif | terminal |
| Hermes | oui | facultatif puis Mattermost | terminal |
| Pi Coding Agent | oui | facultatif | terminal |
| Goose | oui | facultatif | terminal |
| OpenClaw | oui pour exploitation et session | oui pour ses surfaces conversationnelles autorisées | les deux |
| OpenHands | commandes de gestion seulement | oui | portail |
| OpenWebUI | commandes de gestion seulement | oui | portail |
| ComfyUI | commandes de gestion seulement | oui | portail |
| Forgejo | commandes de gestion seulement | oui | portail |
| Grafana / observabilité | diagnostics CLI | oui | portail |
| Catalogue / RAG | oui pour automatisation | oui | portail |
| Modèles / Ollama gate | oui pour administration autorisée | oui | les deux |
| Scheduler / quotas / coûts | oui pour automatisation et diagnostic | oui | portail |
| Sauvegarde / update / rollback / doctor | oui | oui pour les opérations guidées | les deux |
| Mattermost / Dify | gestion CLI seulement | oui | portail |

Cette matrice est un minimum. Une application peut obtenir une seconde surface plus tard, mais aucune fonctionnalité ne peut être déclarée terminée sans au moins un chemin utilisateur opérationnel.

#### 5.1.4 Architecture interne correspondante

```text
Utilisateur terminal                     Utilisateur navigateur
        │                                         │
        ▼                                         ▼
agent <composant> [projet]                    portail web
        │                                         │
        └───────────────► control-api ◄───────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
      runtime-controller    scheduler      identités/approbations
              │
              ▼
       AgentRuntimeAdapter
              │
              ▼
        SandboxRuntime
      ┌───────┼────────┐
      ▼       ▼        ▼
Docker durci OpenShell Kubernetes futur
              │
              ▼
          ollama-gate
       ┌──────┴─────────┐
       ▼                ▼
    Ollama        TensorRT-LLM
```

#### 5.1.5 Tests de parcours utilisateur

- `agent codex` ouvre ou reprend Codex sans demander d’abord un projet ;
- `agent codex ARTANY` ouvre directement le workspace ARTANY ;
- une déconnexion puis reconnexion SSH retrouve la session ;
- le changement de projet ne change pas d’agent et n’expose aucune donnée du projet précédent ;
- chaque application web est ouvrable depuis le portail sans connaître son port ;
- un utilisateur ne voit pas une application ou une commande hors de ses droits ;
- chaque ligne de la matrice possède au moins un test de disponibilité, d’authentification et de persistance ;
- aucun vocabulaire Docker ou Compose n’apparaît dans le parcours utilisateur normal.

### 5.2 Plan de contrôle

Socle retenu :

- FastAPI/Python ;
- PostgreSQL comme état canonique ;
- workers Python ;
- frontend React ou Next.js ;
- API REST pour les opérations, WebSocket / Server-Sent Events (SSE) pour les événements ;
- le CLI `agent` devient un client léger de l’API, pas un second moteur métier ;
- fichiers YAML déclaratifs importables/exportables, validés par schéma ;
- migrations de base versionnées ;
- journal d’événements et identifiants de corrélation de bout en bout.

Le plan de contrôle de confiance peut piloter Docker. Aucun autre composant ne reçoit ce privilège.

### 5.3 Identités, organisations et projets

- rôles humains initiaux : administrateur principal, utilisateur de confiance, standard, invité ;
- agents comme identités organisationnelles persistantes avec nom, équipe, rôle, responsable humain et prérogatives ;
- sous-agents autorisés, mais droits strictement inclus dans ceux du parent et du projet ;
- délégations explicites lorsqu’un agent agit au nom d’un humain ;
- ressources communes par défaut, avec niveaux `commun`, `projet`, `privé utilisateur`, `secret` ;
- création de projet minimale, puis configuration progressive ;
- portail vide au premier démarrage.

### 5.4 Exposition réseau

Profils :

- `local` : loopback uniquement ;
- `lan` : adresse LAN explicite, profil par défaut demandé ;
- `tailscale` : adresse Tailscale explicite ;
- `https-tunnel` ou `https-public` : option avancée, désactivée par défaut.

Invariants :

- jamais de bind wildcard `0.0.0.0` ;
- authentification obligatoire ;
- Ollama `11434`, bases, adapters, workers, sandboxes et backends restent internes ;
- Tailscale n’est pas exécuté dans les conteneurs ;
- HTTPS est requis pour passkeys/biométrie ; le portail doit proposer un chemin sécurisé compatible ou désactiver proprement ces fonctions en HTTP local.

### 5.5 Politique d’egress révisée

La v2 ne reproduit pas une allowlist trop restrictive pour les usages ordinaires.

Politique par défaut :

- HTTPS Web autorisé pour les agents dans leur scope ;
- blocage des réseaux privés non autorisés, services de métadonnées des clouds, loopback hôte et endpoints sensibles ;
- blocage de destinations malveillantes/phishing connues ;
- DNS et egress audités ;
- contenu Web toujours considéré comme non fiable ;
- les instructions trouvées sur le Web ne peuvent jamais accorder de permissions ;
- override humain temporaire et traçable ;
- mode strict allowlist disponible pour projets sensibles ;
- fonctionnement hors ligne possible sans dégrader les fonctions locales.

### 5.6 Passerelle LLM et modèles

- `ollama-gate` expose les API OpenAI `/v1/...` et Ollama d’inférence `/api/...` ;
- embeddings préférés via `/api/embed` avec `input`, fallback `/api/embeddings` avec `prompt` ;
- modèle d’embedding initial configurable, préférence `nomic-embed-text` ;
- mêmes clés, identités, quotas, priorités et logs pour les deux familles d’API ;
- opérations de téléchargement, import, conversion, création et suppression réservées au portail/CLI administrateur avec confirmation humaine ;
- chargement d’un modèle existant automatique seulement si l’admission ne perturbe pas les services au-delà de la politique ;
- catalogue global Ollama, Hugging Face, ComfyUI et TensorRT-LLM ;
- aucune suppression automatique, même pour les caches ;
- proposition de nettoyage avec estimation du gain, puis validation humaine.

### 5.7 Sandbox et runtime agents

Interface canonique `AgentRuntimeAdapter` :

- `capabilities()` ;
- `prepare()` ;
- `start()` / `stop()` / `status()` ;
- `create_session()` / `resume_session()` ;
- `run_task()` avec streaming ;
- `cancel()` ;
- `checkpoint()` / `restore()` lorsque supporté ;
- `mount_workspace()` ;
- `inject_secret_reference()` ;
- `collect_usage()` ;
- `health()` ;
- `export_state()` / `import_state()`.

Interface `SandboxRuntime` :

- création et destruction contrôlées ;
- image et provenance ;
- identifiants utilisateur et groupe non root ;
- système de fichiers racine en lecture seule quand possible ;
- volumes déclarés ;
- CPU, mémoire, GPU et stockage ;
- réseau et egress ;
- secrets temporaires ;
- logs et métriques ;
- aucune exposition du socket Docker.

Backends :

1. `docker-hardened` : obligatoire et stable ;
2. OpenShell : expérimental derrière l’interface, version épinglée ;
3. Kubernetes : futur, sans impact sur les contrats applicatifs.

### 5.8 Ordonnanceur et ressources

- priorité interactive ;
- modes `normal`, `burst`, `exclusive` ;
- profils standards et profils personnalisés dans les quotas ;
- dépendances et services à préserver/arrêter ;
- tâches `checkpointable`, `pausable` ou `non_preemptible` ;
- drain coopératif avec délai annoncé ;
- créneau recalculé en conservant la durée de calcul promise ;
- administrateur souverain après délai de grâce ;
- négociation structurée entre agents, décision humaine finale ;
- priorité de base par utilisateur, puis projet, puis tâche ;
- concurrence adaptative selon mesures réelles ;
- Ollama peut être arrêté pour une tâche exclusive qui n’en dépend pas ;
- portail avec calendrier, demandes, conflits, consommation et dépassements.

### 5.9 Secrets et actions externes

- courtier local ;
- stockage chiffré ;
- injection temporaire par fichier mémoire, jeton court ou proxy ;
- secret jamais copié dans mémoire agent, RAG ou logs ;
- secrets individuels ou partagés par équipe/projet ;
- propriétaire et rotation ;
- accès automatique dans le scope, approbation sinon ;
- action au nom d’un humain seulement avec délégation explicite ;
- audit de l’acteur réel, du mandant, du scope et du résultat.

### 5.10 Catalogue, mémoire et RAG

- portail initial vide ;
- répertoires déclarés par projet ;
- découverte sans copie ;
- métadonnées, provenance, droits, confidentialité et disponibilité ;
- tous formats visés progressivement ;
- première indexation validée par un humain ayant lecture ;
- réindexation automatique après modification autorisée ;
- revalidation si droits, confidentialité ou structure changent fortement ;
- mutualisation des chunks/embeddings compatibles ;
- agents autorisés à créer et publier des collections ;
- publication dans le socle commun avec statut initial non validé ;
- mémoire globale d’agent, confidentialité par projet ;
- collection prioritaire facultative, sinon recherche générale sur le scope accessible ;
- sources et passages exacts toujours affichés pour le RAG ;
- connaissance générale autorisée sans fausse référence ;
- réponses mixtes fluides avec marquage discret.

### 5.11 Collaboration Mattermost et Dify

Deuxième incrément, après stabilisation du cœur et migration des fonctions existantes :

- Mattermost : collaboration humains–agents ;
- Dify : workflows, routage et validations ;
- gateway central ;
- compte bot distinct par agent visible ;
- adapters OpenClaw, Hermes puis tous les autres via le même contrat ;
- aucun socket Docker, aucun `docker exec`, aucun accès direct aux backends modèles ;
- images ARM64 vérifiées et épinglées ;
- services optionnels, non démarrés au premier lancement ;
- boucles autonomes illimitées interdites.

## 6. Migration des données et états

### 6.1 Classification

Chaque donnée est classée avant import :

- **à préserver sans transformation** : dépôts Git, workspaces, résultats importants, modèles ;
- **à exporter/importer** : identités, secrets, config, conversations, approvals, catalogues ;
- **à migrer par outil officiel** : bases PostgreSQL, Forgejo, OpenWebUI, OpenHands, Qdrant ;
- **à reconstruire** : index RAG incompatibles, caches, images dérivées ;
- **à abandonner explicitement** : artefacts temporaires sans valeur.

Aucune donnée n’est supprimée parce qu’elle « semble inutile ».

### 6.2 Stratégie par agent

Pour chaque runtime :

1. arrêter proprement ou checkpoint ;
2. exporter manifeste, versions et état ;
3. monter le workspace v1 en lecture seule dans un importeur ;
4. copier uniquement dans le nouveau workspace géré ;
5. importer configuration autorisée et secrets par références ;
6. exécuter un scénario de parité ;
7. conserver la source v1 intacte jusqu’à validation ;
8. produire un rapport d’import avec fichiers préservés, ignorés et régénérés.

### 6.3 Modèles

Pendant le fonctionnement en ombre :

- store v1 monté en lecture seule côté v2 ;
- téléchargements v2 dans un espace séparé ;
- comparaison par empreinte ;
- aucune copie si le fichier est identique ;
- après bascule, transfert explicite du rôle d’écriture au gestionnaire v2 ;
- rollback capable de rendre le store à la v1.

### 6.4 RAG et bases

- préférer snapshots officiels quand schéma compatible ;
- sinon réindexer depuis le catalogue, pas depuis des fragments opaques ;
- conserver la provenance et les droits ;
- valider le nombre de sources, chunks, collections et empreintes ;
- vérifier qu’aucune ressource privée n’est devenue visible.

## 7. Refonte complète de la documentation

La documentation fait partie du produit et possède sa propre porte de validation.

### 7.1 Documents à réécrire

- `README.md` : landing page v2, état de migration et choix du chemin v1/v2 pendant la transition ;
- `README.en.md` et `README.fr.md` : parité de contenu et quickstarts vérifiés ;
- `AGENTS.md` : règles de développement v2, Beads-first, contrats, tests, documentation et interdiction de contourner le plan de contrôle ;
- `docs/architecture/` : vue système, frontières de confiance, flux réseau, données, agents, modèles, scheduler ;
- `docs/decisions/` : ADR pour chaque choix structurant ;
- `docs/migration/` : inventaire, sauvegarde, imports, canari, bascule, rollback ;
- `docs/runbooks/` : installation, utilisateurs, agents, modèles, ressources, incidents, backup/restore, update/rollback ;
- `docs/security/` : modèle de menace, secrets, egress, supply chain, délégations, prompt injection ;
- `docs/user/` : portail, projets, collections, approvals, rapports ;
- `docs/agents/` : contrat adapter et guide par runtime ;
- `docs/api/` : OpenAPI générée, événements, exemples ;
- `docs/operations/` : métriques, alertes, capacité, maintenance ;
- `CHANGELOG.md` et guide de version.

### 7.2 Gestion de la documentation v1

- la branche d’archive conserve l’original ;
- pendant la transition, les pages v1 restantes sont marquées `legacy-v1` et indiquent leur version ;
- aucune page v1 n’est supprimée avant que sa page v2 de remplacement soit testée ;
- après bascule, la documentation v1 est retirée de la navigation principale mais reste accessible dans l’archive.

### 7.3 Documentation exécutable

- extraits de commandes testés en CI ;
- liens vérifiés ;
- schémas de configuration validés ;
- OpenAPI générée depuis le code ;
- aide `agent --help` comparée à la documentation ;
- matrice ports/volumes/secrets générée depuis les manifestes ;
- matrice des accès CLI/portail générée et testée ;
- chaque phase met à jour la documentation avant fermeture.

## 8. Stratégie de tests

### 8.1 Niveaux

1. tests de schémas et contrats ;
2. tests unitaires ;
3. tests Compose statiques et hardening ;
4. tests de composants ;
5. tests d’intégration ;
6. tests agent-par-agent ;
7. tests de bout en bout multi-services ;
8. tests migration/import ;
9. tests backup/restore ;
10. tests performance et admission ;
11. tests panne/rollback ;
12. tests documentation et parcours utilisateur.

### 8.2 Matrice de parité agent

Le scénario commun obligatoire pour chaque agent :

1. identité et projet créés ;
2. runtime préparé ;
3. dépôt de test cloné depuis Forgejo ;
4. branche agent utilisée, jamais `main` ;
5. lecture et modification multi-fichiers ;
6. tests du dépôt exécutés ;
7. appel modèle uniquement via `ollama-gate` ;
8. accès outil et RAG selon permissions ;
9. action sensible mise en attente d’approbation ;
10. métriques et coûts attribués ;
11. arrêt/checkpoint puis reprise ;
12. publication du résultat ;
13. audit complet et absence de secret ;
14. accès par la surface principale annoncée dans la matrice 5.1.3.

Les différences de capacités sont déclarées, jamais masquées.

### 8.3 Jeu de tests de référence

Conserver et porter :

- canari rapide « huit reines » ;
- dépôt réaliste multi-fichiers volontairement cassé ;
- scénarios OpenClaw relay/approvals/pièces jointes ;
- OpenHands UI + tâche code ;
- OpenWebUI + modèle local ;
- ComfyUI + image de sortie ;
- RAG avec source et passage ;
- Forgejo avec protection de branche ;
- update/rollback par digest ;
- restauration complète ;
- ouverture de chaque application web depuis le portail ;
- accès à chaque agent CLI par `agent <nom> [projet]`.

## 9. Phases de migration et portes de validation

### Phase M0 — Gel, archive et sauvegarde

**Travaux**

- geler les changements structurants v1 ;
- créer l’archive Git et le tag ;
- produire snapshot runtime et manifeste ;
- sauvegarder secrets chiffrés ;
- restaurer dans une racine isolée ;
- capturer résultats de tests, ressources et performances de référence.

**Porte G0**

- archive Git lisible ;
- snapshot complet ;
- restauration v1 fonctionnelle ;
- rapport signé par l’administrateur.

### Phase M1 — Inventaire et registre de parité

**Travaux**

- inventorier services, ports, volumes, secrets, images, agents, commandes et tests ;
- associer chaque fonction à `preserve`, `replace`, `rebuild` ou `retire`;
- aucune fonction `retire` sans décision humaine ;
- créer les epics et tâches Beads réels ;
- établir les scénarios de parité ;
- attribuer à chaque composant une surface CLI, portail ou les deux.

**Porte G1**

- aucune fonctionnalité ou agent sans propriétaire, phase et test ;
- couverture explicite de Claude, Codex, OpenCode, KiloCode, VibeStral, Hermes, Pi, Goose, OpenClaw et OpenHands ;
- aucune application sans chemin d’accès utilisateur défini.

### Phase M2 — Documentation et contrats v2 avant code

**Travaux**

- réécrire `AGENTS.md` ;
- créer ADR architecture/identités/runtime/gateway/réseau/migration ;
- définir OpenAPI, schémas YAML, `AgentRuntimeAdapter`, `SandboxRuntime`, tâche, approval, usage et événement ;
- définir le contrat de surface utilisateur CLI/portail ;
- créer le squelette documentaire v2 ;
- transformer le README en page de transition claire.

**Porte G2**

- contrats validés par tests de schéma ;
- documentation de développement non contradictoire ;
- matrice CLI/portail complète ;
- aucun code v2 autorisé avant cette porte.

### Phase M3 — Squelette du plan de contrôle

**Travaux**

- FastAPI, PostgreSQL, migrations, workers, frontend vide, CLI `agent` ;
- même source d’état ;
- healthchecks, logs, métriques et corrélation ;
- installation/désinstallation sans modification globale cachée ;
- portail vide au premier démarrage.

**Porte G3**

- portail, CLI `agent` et YAML produisent le même état ;
- backup/restore de la base ;
- aucune dépendance à Internet ;
- aucun projet implicite.

### Phase M4 — Sécurité, identités, projets et secrets

**Travaux**

- authentification locale, rôles, agents, sous-agents, scopes et délégations ;
- secret broker ;
- reverse proxy et profils d’exposition ;
- egress révisé ;
- terminal administrateur audité ;
- rétention audit 30 jours.

**Porte G4**

- tests de séparation des droits ;
- aucun secret dans logs/mémoire ;
- aucun wildcard bind ;
- LAN explicite et mode hors ligne validés.

### Phase M5 — Plan modèle et catalogue global

**Travaux**

- porter `ollama-gate` ;
- compatibilité OpenAI et Ollama ;
- quotas, priorités et identité ;
- catalogue de modèles ;
- import du store existant ;
- TensorRT-LLM optionnel ;
- benchmarks, warm-up, contexte et compaction.

**Porte G5**

- API de parité ;
- aucune exposition `11434` ;
- modèles v1 réutilisés sans duplication ;
- aucun pull/delete sans approbation ;
- rollback vers le gate v1 possible.

### Phase M6 — Sandbox Docker et ordonnanceur

**Travaux**

- implémenter `SandboxRuntime` Docker ;
- scheduler, admission, profils, drain, checkpoint et reprise ;
- quotas utilisateur/projet et estimation des coûts ;
- builder isolé et provenance des images ;
- OpenShell uniquement expérimental derrière feature flag.

**Porte G6**

- aucun socket Docker dans les runtimes non fiables ;
- tâches normales, burst et exclusives validées ;
- préemption coopérative et force admin testées ;
- latence interactive protégée.

### Phase M7 — Migration des agents CLI

#### Vague 1 : Codex et Claude Code

Ils servent de canaris du contrat générique et du parcours `agent <nom> [projet]`.

#### Vague 2 : OpenCode, KiloCode, VibeStral et Hermes

Hermes peut garder un adapter spécialisé si ses capacités l’exigent, mais il respecte le même contrat externe.

#### Vague 3 : Pi et Goose

Modules optionnels mais entièrement supportés avant retrait v1.

**Porte G7 par agent**

- import d’état documenté ;
- scénario de parité complet ;
- ouverture directe par `agent <nom>` ;
- sélection facultative du projet ;
- reprise après arrêt ou déconnexion ;
- aucune régression de workspace ;
- gate, outils, RAG, secrets, quotas et audit validés.

La phase ne ferme pas avec un simple succès Codex.

### Phase M8 — Migration d’OpenClaw et OpenHands

**OpenClaw**

- API, gateway, relay, sandbox, approvals, overlays, pièces jointes, skills, mémoire et workspaces ;
- accès CLI d’exploitation et surface conversationnelle web autorisée ;
- aucune double exécution ;
- export/import d’état ;
- chat status et surfaces opérateur.

**OpenHands**

- UI accessible depuis le portail, conversations, workspace, modèle, outils et persistance ;
- commandes CLI de gestion ;
- aucun socket Docker ;
- limites ressources et intégration scheduler.

**Porte G8**

- scénarios de bout en bout dédiés verts ;
- chemins CLI/portail conformes à la matrice ;
- état persistant après redémarrage ;
- approvals et sandbox non contournables.

### Phase M9 — Migration des services utilisateurs

**Travaux**

- OpenWebUI ;
- ComfyUI ;
- Forgejo et comptes agents ;
- MCP catalog ;
- Portainer optionnel avec restrictions ;
- portail comme launcher et contrôle d’accès ;
- commandes `agent` de gestion pour les applications concernées.

**Porte G9**

- parité fonctionnelle et données ;
- chaque application web est accessible depuis le portail ;
- aucun utilisateur n’a besoin de connaître un port ;
- branches Forgejo protégées ;
- ComfyUI planifiable et sorties cataloguées.

### Phase M10 — Catalogue, mémoire et RAG

**Travaux**

- catalogue projet ;
- import des sources v1 ;
- collections, publications, validation et droits ;
- réindexation contrôlée ;
- citations et passages ;
- mémoires agents et connaissances communes.

**Porte G10**

- aucun corpus implicite ;
- aucune fuite inter-projet ;
- déduplication embeddings ;
- réponse RAG toujours sourcée ;
- fallback général sans fausse citation.

### Phase M11 — Observabilité, sauvegarde, release et rollback v2

**Travaux**

- métriques hôte, conteneurs, GPU, modèles, agents, scheduler, quotas et gateway ;
- journaux structurés ;
- sauvegarde quotidienne chiffrée sur disque externe ;
- disque protégé hors fenêtre ;
- release globale testée ;
- environnement de validation éphémère ;
- snapshots/digests et rollback.

**Porte G11**

- restauration v2 complète ;
- rollback applicatif et données ;
- modèles/gros datasets exclus mais catalogués ;
- perte maximale de données de 24 h et remise en service en 24 h documentées et testées.

### Phase M12 — Collaboration Mattermost/Dify

**Travaux**

- validation ARM64 et budget mémoire ;
- Mattermost, Dify, gateway et adapters ;
- comptes bots ;
- approbations humaines ;
- ouverture depuis le portail ;
- commandes CLI de gestion ;
- OpenClaw et Hermes canaris, puis contrat appliqué aux autres agents.

**Porte G12**

- services optionnels ;
- aucun accès direct modèle, socket Docker ou egress incontrôlé ;
- corrélation Mattermost → Dify → gateway → agent → gate ;
- anti-boucle et déduplication.

### Phase M13 — Fonctionnement en ombre

**Travaux**

- v1 reste l’instance de référence ;
- v2 traite des tâches miroir non destructives ;
- comparaison résultats, latence, ressources, erreurs et audit ;
- imports répétés pour prouver l’idempotence ;
- aucun utilisateur obligé de changer immédiatement.

**Porte G13**

- période d’observation sans perte ;
- matrice de parité complète ;
- matrice d’accès CLI/portail complète ;
- écarts résolus ou acceptés explicitement ;
- plan de rollback chronométré.

### Phase M14 — Canari puis bascule

**Canari**

- un administrateur ;
- un projet ;
- Codex accessible par `agent codex [projet]` ;
- une application accessible depuis le portail ;
- un agent service ;
- un modèle existant ;
- un corpus RAG ;
- services v1 toujours disponibles.

**Bascule**

- gel court des écritures v1 ;
- dernier export incrémental ;
- import et validation ;
- changement des endpoints/launcher ;
- tests rapides ;
- surveillance renforcée.

**Rollback**

- arrêt des écritures v2 ;
- export des deltas ;
- remise en service v1 ;
- restauration des endpoints ;
- rapport d’incident.

**Porte G14**

- validation humaine explicite ;
- deux cycles complets de tests sans anomalie bloquante ;
- rollback encore possible.

### Phase M15 — Retrait contrôlé de la v1

La v1 n’est retirée qu’après :

- validation de toutes les fonctions conservées ;
- restauration v2 réussie ;
- documentation finale publiée ;
- absence de dépendance active ;
- décision humaine.

Actions :

- conserver archive Git, manifestes et sauvegarde finale ;
- arrêter les services v1 ;
- ne supprimer aucune donnée ou modèle automatiquement ;
- proposer un plan de nettoyage ;
- retirer l’ancienne documentation de la navigation principale ;
- clôturer les Beads de migration.

## 10. Mise à jour et release

- versions et digests épinglés ;
- aucune mise à jour automatique ;
- proposition lisible des changements ;
- validation dans un environnement isolé ;
- modèles existants montés en lecture seule pendant les tests ;
- tests GPU séquentiels ;
- snapshot avant bascule ;
- courte interruption acceptée ;
- rollback global ;
- schémas de base versionnés et migrations descendantes ou procédure restaurée.

## 11. Définition de terminé pour la refonte

La refonte est terminée seulement si :

- la branche d’archive et les sauvegardes sont restaurables ;
- tous les agents listés ont leur test de parité vert ;
- toutes les fonctions v1 conservées figurent dans le registre et sont validées ;
- portail, CLI `agent` et configuration déclarative sont cohérents ;
- chaque agent ou application possède au moins un accès utilisateur testé par CLI ou portail ;
- le premier démarrage est vide et simple ;
- LAN, Tailscale optionnel et hors ligne sont documentés et testés ;
- aucun service non autorisé n’est exposé ;
- aucun runtime non fiable ne possède le socket Docker ;
- les modèles passent uniquement par `ollama-gate` ;
- scheduler, quotas, coûts, secrets, délégations, catalogue, RAG et backup sont opérationnels ;
- update et rollback par digest sont validés ;
- la documentation FR/EN, développeur, utilisateur, opérateur, sécurité et API est à jour ;
- les anciennes instructions contradictoires ne figurent plus dans la branche principale ;
- l’administrateur a approuvé la bascule et le retrait de la v1.

## 12. Ordre impératif

```text
M0 sauvegarde
→ M1 inventaire
→ M2 documentation et contrats
→ M3 plan de contrôle
→ M4 identités/sécurité
→ M5 modèles
→ M6 sandbox/scheduler
→ M7 agents CLI
→ M8 OpenClaw/OpenHands
→ M9 services utilisateurs
→ M10 catalogue/RAG
→ M11 exploitation/backup
→ M12 collaboration
→ M13 ombre
→ M14 canari/bascule
→ M15 retrait v1
```

Aucune phase ne peut être sautée pour « aller plus vite ». Une fonctionnalité peut être reportée uniquement si elle est nouvelle et optionnelle. Une fonctionnalité ou un agent déjà établi ne peut être perdu sans décision humaine documentée.
