# DGX Spark Agentic Platform v2 — Plan canonique

## 0. Statut et gouvernance

Ce document remplace l’ancienne roadmap comme plan actif de la plateforme.

Référence v1 conservée :

- branche : `archive/pre-v2-rewrite-2026-06-25`
- commit : `f76778e342d43fdafaa17e05ad887f6e9853aa7d`

Règles :

- `PLAN.md` décrit l’architecture, les invariants, les phases et les portes de validation ;
- Beads reste l’unique backlog opérationnel ;
- aucun identifiant Beads n’est inventé ici ;
- aucune phase n’est close sans tests, documentation et validation de sa porte ;
- la migration reste réversible jusqu’au retrait explicite de la v1.

## 1. Objectif

Transformer la stack actuelle en plateforme locale multi-utilisateur et multi-agent :

- simple à installer, utiliser, mettre à jour et retirer ;
- adaptée à une DGX Spark de développement ;
- accessible en local et sur le réseau local avec authentification ;
- utilisable hors Internet pour toutes les fonctions locales ;
- capable de gérer environ trente identités d’agents persistantes avec runtimes à la demande ;
- capable de planifier CPU, mémoire unifiée, GPU et stockage ;
- conservant les agents, applications, données et parcours v1 ;
- utilisant **OpenShell comme runtime principal des agents** ;
- utilisant **NemoClaw comme blueprint de référence pour Hermes et OpenClaw** ;
- utilisant Docker/Compose pour les services de confiance et comme pilote local d’OpenShell ;
- préparée à utiliser Kubernetes comme pilote OpenShell futur.

## 2. Invariants de réussite

La bascule v2 exige :

1. snapshot v1 restauré avec succès ;
2. parité fonctionnelle de chaque fonction conservée ;
3. parité testée de chaque agent ;
4. même API et même état pour portail, CLI `agent` et configuration déclarative ;
5. aucun agent ni service non fiable avec accès direct au socket Docker ;
6. OpenShell comme chemin normal de tous les agents obligatoires ;
7. NemoClaw validé pour Hermes et OpenClaw ;
8. `ollama-gate` comme seul chemin vers Ollama, TensorRT-LLM ou un fournisseur distant ;
9. modèles réutilisés sans duplication inutile ;
10. workspaces, dépôts, états, mémoires et catalogues migrés ou explicitement régénérables ;
11. sauvegarde, restauration, mode LAN, hors ligne et rollback validés ;
12. documentation alignée avec le déploiement réel ;
13. approbation humaine de la bascule.

## 3. Préservation de la v1

Avant tout code v2 :

- créer le tag `v1-pre-v2-migration` ;
- sauvegarder Compose effectif, images, digests, bases, volumes, workspaces, dépôts, états agents, Forgejo, OpenWebUI, OpenHands, OpenClaw, RAG et observabilité ;
- sauvegarder les secrets dans une archive chiffrée séparée ;
- cataloguer modèles et gros jeux de données sans les recopier ;
- restaurer la v1 dans une racine isolée ;
- exécuter `doctor`, un appel modèle, un agent CLI et les applications critiques ;
- bloquer la suite si la restauration n’est pas reproductible.

Deux racines sont conservées pendant la transition :

- `V1_ROOT` pour la v1 ;
- `SPARK_ROOT` pour la v2.

## 4. Fonctions et agents à préserver

### 4.1 Services fondamentaux

| Fonction | Exigence v2 |
|---|---|
| Ollama | interne, jamais exposé directement |
| `ollama-gate` | passerelle OpenAI + Ollama, identités, quotas, priorité, audit |
| TensorRT-LLM | backend interne optionnel |
| routage local/distant | explicite, audité, sans fallback silencieux |
| modèles globaux | dédupliqués, aucune suppression automatique |
| fonctionnement hors ligne | obligatoire |
| egress | gouverné par politiques OpenShell et contrôles plateforme |

### 4.2 Agents

| Agent | Runtime cible | Exigence de parité |
|---|---|---|
| Claude Code | OpenShell + CLI | politique officielle adaptée à `ollama-gate`, dépôt, tests, reprise |
| Codex | OpenShell + CLI | politique personnalisée complète, dépôt, tests, reprise, checkpoint |
| OpenCode | OpenShell + CLI | compléter la couverture officielle partielle |
| KiloCode | OpenShell + CLI | image et politique spécifiques |
| VibeStral | OpenShell + CLI | image et politique spécifiques |
| Hermes | NemoClaw/OpenShell + CLI + dashboard | mémoire, profils, sessions, dashboard, Desktop distant |
| Pi | sandbox OpenShell dédiée + CLI | profil optionnel mais supporté |
| Goose | OpenShell + CLI | politique spécifique, compaction, reprise |
| OpenClaw | NemoClaw/OpenShell + service/API | relay, approvals, pièces jointes, skills, mémoire, reprise |
| OpenHands | UI/service, code non fiable via OpenShell | UI, outils, persistance, aucun socket Docker |
| futurs agents | manifeste OpenShell déclaratif | image, politique, outils, permissions, tests automatiques |

### 4.3 Applications et interfaces

Le portail doit donner accès aux interfaces natives autorisées :

- OpenWebUI ;
- Hermes Web Dashboard et son onglet Chat ;
- Hermes Desktop comme client optionnel du même backend distant ;
- OpenHands ;
- ComfyUI ;
- Forgejo ;
- Grafana ;
- DGX Dashboard NVIDIA ;
- JupyterLab intégré DGX ;
- plus tard Mattermost et Dify.

Aucun utilisateur ne doit connaître un port interne.

## 5. Architecture cible

### 5.1 Accès utilisateur

Chaque composant possède au moins un accès clair :

- terminal via `agent` ;
- portail web ;
- parfois les deux ;
- éventuellement Desktop, extension d’éditeur, mobile ou messagerie comme surface supplémentaire.

Exemples :

```bash
agent codex
agent codex ARTANY
agent claude ARTANY
agent hermes SEGMENTATION-RTMRI
```

L’utilisateur choisit d’abord l’agent. Le projet est un contexte de travail facultatif. Le changement de projet ne change pas d’agent :

```bash
agent project SEGMENTATION-RTMRI
```

La session survit à une déconnexion SSH. OpenShell, Docker, les identifiants de sandbox et les ports sont masqués.

### 5.2 Portail

Le portail est le point d’entrée web unique et authentifié. Il propose :

- agents, tâches et approbations ;
- projets et droits ;
- modèles et quotas ;
- calendrier et ressources ;
- catalogue et RAG ;
- sauvegardes, mises à jour et rollback ;
- journaux, alertes et rapports ;
- applications web natives.

Entrées obligatoires :

- Hermes Dashboard avec accès direct au Chat ;
- DGX Dashboard NVIDIA, administrateurs par défaut ;
- JupyterLab DGX selon l’utilisateur ;
- Grafana ;
- OpenWebUI, OpenHands, ComfyUI et Forgejo.

Le DGX Dashboard et JupyterLab restent derrière tunnel sécurisé, NVIDIA Sync ou reverse proxy strict. Le port `11000` et les ports Jupyter ne sont pas exposés directement au LAN.

### 5.3 Plan de contrôle

Socle :

- FastAPI/Python ;
- PostgreSQL ;
- workers Python ;
- React ou Next.js ;
- REST pour les opérations ;
- WebSocket ou Server-Sent Events pour les événements ;
- CLI `agent` comme client léger de la même API ;
- YAML déclaratif validé par schéma ;
- migrations versionnées et journal d’événements.

Le plan de contrôle de confiance pilote OpenShell et, uniquement pour les services de plateforme ou le fallback de migration, Docker.

### 5.4 Réseau et identité

- rôles : administrateur principal, utilisateur de confiance, standard, invité ;
- agents comme identités persistantes ;
- délégation explicite lorsqu’un agent agit au nom d’un humain ;
- niveaux : commun, projet, privé utilisateur, secret ;
- profils réseau : local, LAN, Tailscale optionnel, HTTPS avancé ;
- aucun bind wildcard ;
- aucune base, gateway agent, sandbox ou backend modèle exposé directement ;
- Tailscale reste sur l’hôte.

### 5.5 Egress

Par défaut :

- HTTPS autorisé dans le scope ;
- blocage réseaux privés non autorisés, métadonnées cloud, loopback hôte et destinations malveillantes ;
- DNS et egress audités ;
- contenu Web considéré comme non fiable ;
- aucune instruction Web ne peut accorder un droit ;
- override humain temporaire et tracé ;
- mode allowlist strict pour projets sensibles ;
- traduction en politiques OpenShell testables.

### 5.6 Modèles

- `ollama-gate` expose les API OpenAI `/v1/...` et Ollama `/api/...` ;
- OpenShell `inference.local` et NemoClaw pointent exclusivement vers `ollama-gate` ;
- embeddings : `/api/embed` avec `input`, fallback `/api/embeddings` avec `prompt` ;
- préférence initiale `nomic-embed-text` ;
- téléchargement, import, conversion et suppression réservés à l’administration avec confirmation ;
- aucune suppression automatique.

### 5.7 OpenShell et NemoClaw

#### 5.7.1 Décision

**OpenShell est obligatoire et prioritaire pour les agents dès M6.** Il n’est plus une expérimentation tardive.

Répartition :

- Docker/Compose exécute les services de confiance ;
- OpenShell crée, isole, gouverne et observe les agents ;
- le premier pilote OpenShell est Docker, officiellement supporté en mono-machine ;
- NemoClaw est le blueprint initial de Hermes et OpenClaw ;
- Kubernetes devient un pilote OpenShell futur ;
- MicroVM est évalué après bascule pour les projets sensibles ;
- Docker direct `docker-hardened` ne sert qu’à la migration, au diagnostic et au rollback.

OpenShell supporte Linux ARM64. L’architecture DGX Spark est donc une cible normale, pas une preuve de concept.

#### 5.7.2 Contrat agent

`AgentRuntimeAdapter` expose au minimum :

- capacités ;
- préparation ;
- démarrage, arrêt, état ;
- création et reprise de session ;
- exécution avec streaming ;
- annulation ;
- checkpoint et restauration si disponibles ;
- montage workspace ;
- références de secrets ;
- usage, santé, export et import d’état.

L’implémentation par défaut est `OpenShellAgentRuntime`. Aucun adapter ne contourne OpenShell pour aller plus vite.

#### 5.7.3 Politiques OpenShell

Chaque agent possède :

- image ou blueprint versionné et signé ;
- politique fichiers et montages ;
- politique réseau ;
- politique processus et appels système ;
- provider d’inférence vers `ollama-gate` ;
- secrets temporaires ;
- limites CPU, mémoire, GPU, processus et stockage ;
- journaux d’autorisations et refus ;
- export/import et reprise.

`seccomp` est obligatoire. Landlock utilise `hard_requirement` lorsque le noyau et le profil le permettent ; toute dégradation est explicite et testée.

#### 5.7.4 NemoClaw

NemoClaw devient :

- blueprint de production d’OpenClaw ;
- blueprint initial d’Hermes si toutes ses fonctions CLI, dashboard, mémoire, outils et gateway sont préservées ;
- référence de structure pour réseau, inférence routée, durcissement et cycle de vie des agents permanents.

Son statut alpha impose versions épinglées, tests renforcés et rollback ; il ne justifie pas son exclusion du chemin principal.

#### 5.7.5 Couverture

- Claude Code : couverture OpenShell complète comme base ;
- Codex : image disponible, politique personnalisée obligatoire ;
- OpenCode : couverture partielle à compléter ;
- Pi : sandbox dédiée ;
- Hermes et OpenClaw : NemoClaw/OpenShell ;
- KiloCode, VibeStral et Goose : images et politiques spécifiques ;
- OpenHands : exécution non fiable via OpenShell.

#### 5.7.6 Retrait du fallback Docker direct

Le fallback est désactivé par défaut après bascule et retiré lorsque :

1. tous les agents obligatoires passent sous OpenShell ;
2. GPU, réseau, secrets, reprise et hors ligne sont verts ;
3. Hermes et OpenClaw passent sous NemoClaw ;
4. deux cycles de fonctionnement en ombre sont concluants ;
5. le rollback v1 ne dépend plus du fallback.

Il ne peut pas devenir un second runtime permanent par inertie.

### 5.8 Ordonnanceur

- priorités interactives ;
- modes normal, burst, exclusif ;
- quotas utilisateur/projet ;
- tâches checkpointables, pausables ou non préemptibles ;
- drain coopératif ;
- décision administrateur après délai de grâce ;
- admission selon CPU, mémoire, GPU, stockage et services à préserver ;
- création et destruction des sandboxes via OpenShell.

### 5.9 Secrets

- courtier local ;
- stockage chiffré ;
- injection temporaire ;
- aucun secret dans image, workspace, mémoire, RAG ou logs ;
- scopes utilisateur, équipe et projet ;
- rotation et propriétaire ;
- délégation et audit du mandant réel.

### 5.10 Catalogue, mémoire et RAG

- portail initial vide ;
- sources déclarées par projet ;
- découverte sans copie ;
- provenance, droits et confidentialité ;
- première indexation validée par un humain ;
- réindexation automatique après modification autorisée ;
- déduplication des chunks et embeddings compatibles ;
- mémoire globale d’agent avec confidentialité par projet ;
- toute réponse RAG affiche sources et passages exacts.

### 5.11 Mattermost et Dify

Deuxième incrément après stabilisation du cœur :

- Mattermost pour la collaboration humains-agents ;
- Dify pour workflows et validations ;
- compte bot distinct par agent ;
- OpenClaw et Hermes comme canaris ;
- chaque tâche agent passe par OpenShell/NemoClaw ;
- aucun accès direct Docker ou modèle ;
- anti-boucle, déduplication et corrélation complète.

## 6. Migration des données

Pour chaque agent :

1. arrêt propre ou checkpoint ;
2. export manifeste, versions et état ;
3. workspace v1 monté en lecture seule ;
4. image, blueprint et politique OpenShell produits ;
5. configuration et secrets importés par références ;
6. scénario de parité sous OpenShell ;
7. source v1 conservée jusqu’à validation ;
8. rapport d’import produit.

Modèles : store v1 en lecture seule pendant l’ombre, comparaison par empreinte, aucune copie si identique, transfert explicite du rôle d’écriture après bascule.

RAG : snapshots officiels si compatibles, sinon réindexation depuis les sources cataloguées avec conservation des droits et provenance.

## 7. Documentation

À réécrire ou créer :

- README FR/EN ;
- `AGENTS.md` ;
- architecture et frontières de confiance ;
- ADR, dont OpenShell obligatoire et NemoClaw de référence ;
- migration et retrait du fallback Docker direct ;
- runbooks OpenShell, NemoClaw, agents, modèles, incidents et restauration ;
- sécurité, politiques, secrets, egress et supply chain ;
- guide portail et interfaces ;
- guide par agent avec image, blueprint et politique ;
- API, opérations et changelog.

La documentation est exécutable : commandes testées, liens vérifiés, OpenAPI générée, schémas validés, matrices ports/volumes/secrets/politiques générées.

## 8. Tests

### 8.1 Niveaux

- contrats et schémas ;
- unitaires ;
- Compose, OpenShell, NemoClaw et politiques ;
- composants et intégration ;
- agent par agent ;
- bout en bout ;
- migration et import ;
- backup/restore ;
- performance, admission, panne et rollback ;
- documentation et parcours utilisateur.

### 8.2 Scénario commun par agent

1. identité et projet ;
2. sandbox OpenShell avec image, politique, provider et limites ;
3. dépôt Forgejo ;
4. branche agent, jamais `main` ;
5. modification multi-fichiers ;
6. tests ;
7. modèle uniquement via OpenShell puis `ollama-gate` ;
8. outils et RAG selon droits ;
9. approbation d’une action sensible ;
10. usage et coûts ;
11. arrêt/checkpoint et reprise ;
12. publication ;
13. audit sans secret ;
14. cohérence des interfaces ;
15. tests négatifs fichiers, réseau, processus et secrets.

### 8.3 Canaris obligatoires

- Codex avec politique OpenShell personnalisée ;
- Claude Code sous OpenShell ;
- OpenCode avec couverture complétée ;
- Hermes sous NemoClaw/OpenShell, CLI et dashboard ;
- OpenClaw sous NemoClaw/OpenShell ;
- OpenHands avec code non fiable dans OpenShell ;
- comparaison OpenShell contre fallback Docker avant retrait ;
- OpenWebUI, ComfyUI, Forgejo, RAG, DGX Dashboard et JupyterLab ;
- update/rollback et restauration complète.

## 9. Phases et portes

### M0 — Gel et sauvegarde

Archive, tag, snapshot, secrets chiffrés et restauration v1.

**G0 :** restauration v1 complète et rapport validé.

### M1 — Inventaire et parité

Inventorier fonctions, interfaces, données, agents, images et couverture OpenShell. Décider pour chaque agent : politique officielle, politique à compléter, blueprint NemoClaw ou politique spécifique.

**G1 :** aucun agent ni composant sans propriétaire, accès, runtime et test.

### M2 — Contrats et documentation avant code

ADR OpenShell/NemoClaw, API, schémas, contrat agent, politiques, blueprints et documentation initiale.

**G2 :** contrats testés et matrices complètes.

### M3 — Plan de contrôle

FastAPI, PostgreSQL, workers, portail vide, CLI `agent`, état et événements communs.

**G3 :** portail, CLI et YAML cohérents ; backup de la base.

### M4 — Identités et sécurité

Rôles, projets, délégations, courtier de secrets, réseau, egress et politiques OpenShell.

**G4 :** séparation des droits, refus testés, aucun secret exposé.

### M5 — Modèles

`ollama-gate`, providers OpenShell/NemoClaw, catalogue, import modèles, TensorRT-LLM optionnel.

**G5 :** aucun contournement de `ollama-gate`, aucune exposition `11434`.

### M6 — OpenShell, NemoClaw et scheduler

- OpenShell épinglé sur DGX Spark ARM64 ;
- gateway avec pilote Docker ;
- `OpenShellAgentRuntime` par défaut ;
- NemoClaw intégré pour Hermes et OpenClaw ;
- politiques identité, workspaces, secrets, egress et inférence ;
- scheduler, quotas, checkpoint, GPU et mémoire unifiée ;
- fallback Docker direct uniquement migration/rollback.

**G6 :** OpenShell par défaut, ARM64 validé, politiques positives et négatives vertes, GPU validé, rollback démontré.

### M7 — Agents CLI sous OpenShell

- vague 1 : Claude Code et Codex ;
- vague 2 : OpenCode, KiloCode, VibeStral et Hermes ;
- vague 3 : Pi et Goose.

**G7 par agent :** image/blueprint, politique, parité, reprise, interfaces, refus de sécurité et absence de fallback dans le parcours normal.

### M8 — OpenClaw et OpenHands

OpenClaw sous NemoClaw/OpenShell. OpenHands conserve son UI mais délègue toute exécution non fiable à OpenShell.

**G8 :** scénarios dédiés verts, approvals non contournables.

### M9 — Applications et système

OpenWebUI, Hermes Dashboard, ComfyUI, Forgejo, Grafana, DGX Dashboard et JupyterLab dans le portail.

**G9 :** accès sans connaissance des ports, droits et données préservés.

### M10 — Catalogue et RAG

Sources, collections, publication, droits, déduplication et citations.

**G10 :** aucune fuite inter-projet, toute réponse RAG sourcée.

### M11 — Exploitation et sauvegarde

Métriques OpenShell/NemoClaw, GPU, agents, scheduler, sauvegarde chiffrée, release et rollback.

**G11 :** restauration v2 complète et rollback testé.

### M12 — Mattermost/Dify

Collaboration, bots, workflows, approvals et routage vers OpenShell/NemoClaw.

**G12 :** corrélation complète et aucun accès direct Docker/modèles.

### M13 — Fonctionnement en ombre

Comparer v1/Docker direct et v2/OpenShell ; exécuter les canaris NemoClaw ; répéter les imports.

**G13 :** deux cycles sans perte et aucun agent obligatoire dépendant du fallback.

### M14 — Canari et bascule

Canari : Codex, Claude Code, Hermes, OpenClaw, une application, un modèle, un corpus et DGX Dashboard.

Bascule : gel court, import final, activation OpenShell par défaut, désactivation du fallback direct, tests rapides et surveillance.

**G14 :** validation humaine, OpenShell/NemoClaw réellement utilisés, rollback possible.

### M15 — Retrait v1 et fallback

Après validation : arrêter v1, retirer le fallback Docker direct des parcours agents, conserver archives et sauvegardes, proposer le nettoyage sans suppression automatique.

## 10. Mise à jour et release

- versions et digests OpenShell, NemoClaw, images et services épinglés ;
- aucune mise à jour automatique ;
- validation isolée ;
- snapshot avant bascule ;
- tests GPU séquentiels ;
- rollback global ;
- migrations de base versionnées.

## 11. Définition de terminé

La refonte est terminée uniquement si :

- v1 et v2 sont restaurables ;
- tous les agents ont leur parité verte ;
- OpenShell est le runtime normal des agents obligatoires ;
- NemoClaw est validé pour Hermes et OpenClaw ;
- le fallback Docker direct est désactivé par défaut et inutile aux parcours normaux ;
- portail, CLI et configuration déclarative sont cohérents ;
- toutes les interfaces retenues fonctionnent avec la même identité et le même état ;
- aucun service non autorisé n’est exposé ;
- aucun runtime non fiable n’a le socket Docker ;
- tous les modèles passent par `ollama-gate` ;
- scheduler, quotas, secrets, RAG, sauvegarde, update et rollback sont opérationnels ;
- documentation FR/EN et runbooks sont à jour ;
- l’administrateur approuve la bascule et le retrait de la v1.

## 12. Ordre impératif

```text
M0 sauvegarde
→ M1 inventaire
→ M2 contrats et documentation
→ M3 plan de contrôle
→ M4 identités et sécurité
→ M5 modèles
→ M6 OpenShell/NemoClaw/scheduler
→ M7 agents CLI sous OpenShell
→ M8 OpenClaw/OpenHands
→ M9 applications et système
→ M10 catalogue/RAG
→ M11 exploitation/backup
→ M12 collaboration
→ M13 ombre
→ M14 canari/bascule
→ M15 retrait v1 et fallback Docker direct
```

Aucune phase ne peut être sautée. Une fonction ou un agent existant ne peut être retiré sans décision humaine documentée.
