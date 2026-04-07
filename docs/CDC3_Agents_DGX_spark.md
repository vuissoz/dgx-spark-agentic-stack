# CDC DGX Spark Agentic Stack

Version Markdown réécrite à partir de `docs/CDC3_Agents_DGX_spark.docx`, mise à jour pour refléter l'état réel du dépôt au 7 avril 2026.

Ce document remplace le CDC initial comme référence de lecture rapide. Il conserve l'intention d'origine, mais reformule les exigences au regard de l'implémentation effectivement présente dans le repo: profils `strict-prod` / `rootless-dev`, plans Compose séparés, wrapper opérateur `./agent`, snapshots de release, diagnostics `doctor`, git forge interne, OpenClaw en baseline, modules optionnels réellement supportés, et trajectoire de durcissement déjà documentée dans les ADR.

## 1. Objet et périmètre

Le projet vise une stack agentique conteneurisée pour DGX Spark, exploitable en single-user, avec:

- exposition locale uniquement sur `127.0.0.1`,
- accès distant via Tailscale sur l'hôte puis tunnel SSH,
- backend LLM partagé,
- UIs web locales conservées,
- agents CLI persistants pour sessions longues,
- contrôle d'egress raisonnable,
- traçabilité de déploiement,
- rollback opérable,
- conformité vérifiable par script.

Le dépôt n'est plus seulement un prototype de CDC. Il implémente déjà un socle opérationnel structuré autour de six plans:

- `core`: inférence, contrôle, DNS, proxy egress, OpenClaw, outils de diagnostic,
- `agents`: conteneurs CLI persistants,
- `ui`: OpenWebUI, OpenHands, ComfyUI, Forgejo,
- `obs`: Prometheus, Grafana, Loki, exporters,
- `rag`: Qdrant, workers RAG, OpenSearch optionnel dans ce plan,
- `optional`: modules explicitement opt-in.

## 2. Hypothèses d'exploitation

Hypothèses retenues:

- hôte Linux avec Docker Engine et `docker compose`,
- GPU NVIDIA disponible et NVIDIA Container Toolkit fonctionnel,
- stockage local suffisant pour modèles, logs, workspaces et index,
- sessions d'exploitation menées en SSH + `tmux`,
- usage principal en local ou via tunnel, pas d'exposition publique directe.

Profils d'exécution:

- `strict-prod`: profil de référence CDC, racine runtime `/srv/agentic`, contrôles hôte et exigences de conformité strictes,
- `rootless-dev`: profil d'itération, racine runtime sous `${HOME}/.local/share/agentic`, mêmes topologies de services mais checks root-only dégradés en warning quand nécessaire.

Le critère d'acceptation final reste `strict-prod`. `rootless-dev` sert à préparer, tester et documenter sans prétendre à la conformité complète.

## 3. Principes non négociables

Le dépôt formalise désormais les garde-fous suivants:

- aucun bind sur `0.0.0.0`,
- aucun montage `docker.sock` dans les applications et agents,
- egress minimisé et gouverné via proxy + contrôles hôte en `strict-prod`,
- secrets hors git, sous `${AGENTIC_ROOT}/secrets/...`, avec permissions restrictives,
- persistance explicite sous `${AGENTIC_ROOT}`,
- `cap_drop: ALL` et `no-new-privileges:true` par défaut,
- `read_only: true` quand l'application le permet,
- healthchecks et diagnostics automatisés,
- déploiements traçables via release snapshots.

Ces règles ne sont pas seulement documentaires: elles sont recoupées par les Compose, `./agent doctor`, les scripts d'initialisation runtime et les tests shell du dépôt.

## 4. Architecture cible, alignée sur l'état actuel

### 4.1 Plan `core`

Services actuellement structurants:

- `ollama`: backend LLM local partagé,
- `ollama-gate`: point d'entrée unique pour le routage, la journalisation et la compatibilité `/v1`,
- `gate-mcp`: pont MCP interne pour exposer des contrôles autour du gate,
- `openclaw`, `openclaw-provider-bridge`, `openclaw-gateway`, `openclaw-sandbox`, `openclaw-relay`: plan de contrôle agentique désormais intégré au socle,
- `unbound`: résolution DNS interne,
- `egress-proxy`: proxy HTTP(S) central,
- `toolbox`: conteneur de diagnostic,
- `trtllm`: backend interne optionnel via profil Compose `trt`.

Évolution importante par rapport au CDC initial:

- `openclaw` n'est plus traité comme une simple piste optionnelle; il fait partie du `core`,
- `ollama-gate` existe en pratique comme composant de routage et d'audit, même si sa trajectoire d'amélioration continue,
- le plan `core` porte à la fois les garde-fous réseau et une partie du plan de contrôle applicatif.

### 4.2 Plan `agents`

Agents baseline:

- `agentic-claude`,
- `agentic-codex`,
- `agentic-opencode`,
- `agentic-vibestral`.

Contrat commun:

- aucun port exposé,
- sessions longues via `./agent <tool> [project]`,
- isolation state/logs/workspaces par outil,
- consommation GPU interdite dans ces conteneurs,
- accès au LLM via `ollama-gate`,
- intégration au git forge interne pour les scénarios collaboratifs.

Modules agentiques additionnels mais opt-in:

- `optional-pi-mono`,
- `optional-goose`.

### 4.3 Plan `ui`

UIs et services interactifs:

- `openwebui`,
- `openhands`,
- `comfyui`,
- `optional-forgejo` et `optional-forgejo-loopback`.

Point notable: Forgejo n'est plus réellement "optionnel" au sens opérationnel. Le nom de service historique est conservé, mais la forge est convergée par le flux baseline `./agent up ui` ou `./agent first-up`, car plusieurs workflows du dépôt en dépendent.

### 4.4 Plan `obs`

Socle observabilité actuellement implémenté:

- `prometheus`,
- `grafana`,
- `loki`,
- `promtail`,
- `node-exporter`,
- `cadvisor`,
- `dcgm-exporter`.

Ce plan sert à vérifier les hypothèses du CDC avec des preuves: santé des services, métriques GPU, journaux proxy, rétention, saturation disque, incidents de file d'attente ou d'egress.

### 4.5 Plan `rag`

Le dépôt retient une baseline RAG locale:

- `qdrant`,
- `rag-retriever`,
- `rag-worker`,
- `opensearch` selon l'activation du sous-usage concerné.

Le RAG n'est plus seulement une recommandation théorique. Il est matérialisé par un plan Compose séparé, avec persistance dédiée et outillage d'initialisation.

### 4.6 Plan `optional`

Modules explicitement gouvernés par demande opérateur:

- `optional-mcp-catalog`,
- `optional-pi-mono`,
- `optional-goose`,
- `optional-portainer`.

Leur activation exige un opt-in explicite, des fichiers de demande et, si nécessaire, des secrets runtime.

## 5. Contrat de persistance

Le contrat de stockage hôte est aujourd'hui bien plus clair que dans le CDC source.

En `strict-prod`, la racine canonique est `/srv/agentic`, avec notamment:

- `/srv/agentic/ollama/`,
- `/srv/agentic/gate/{config,state,logs}/`,
- `/srv/agentic/trtllm/{models,state,logs}/` si `trt` est actif,
- `/srv/agentic/proxy/`,
- `/srv/agentic/dns/`,
- `/srv/agentic/openwebui/`,
- `/srv/agentic/openhands/`,
- `/srv/agentic/comfyui/`,
- `/srv/agentic/openclaw/...`,
- `/srv/agentic/rag/...`,
- `/srv/agentic/monitoring/`,
- `/srv/agentic/{claude,codex,opencode,vibestral}/{state,logs,workspaces}/`,
- `/srv/agentic/optional/...`,
- `/srv/agentic/shared-ro/`,
- `/srv/agentic/shared-rw/`,
- `/srv/agentic/deployments/{releases,current}/`,
- `/srv/agentic/secrets/`.

En `rootless-dev`, le même contrat s'applique sous `${HOME}/.local/share/agentic`, avec des overrides de workspaces agent dédiés.

## 6. Réseau, exposition et egress

Le modèle d'accès retenu est le suivant:

- tous les ports publiés sur l'hôte sont bindés sur `127.0.0.1`,
- l'accès distant passe par Tailscale vers l'hôte puis par tunnel SSH,
- les services internes communiquent sur des réseaux Docker dédiés,
- les conteneurs qui ont besoin de sortir utilisent `egress-proxy`,
- `strict-prod` ajoute une défense hôte via `DOCKER-USER` pour rendre le bypass proxy visible ou bloqué.

Le CDC initial parlait d'un contrôle d'egress "raisonnable". Le dépôt actuel l'a traduit en:

- variables proxy injectées dans les services concernés,
- DNS interne `unbound`,
- scripts réseau dédiés,
- vérifications `doctor`,
- runbooks et rollback réseau host-side.

## 7. Interface opérateur

Le wrapper `./agent` est désormais la façade opérateur standard du projet. Il implémente déjà une part importante du comportement demandé dans le CDC initial:

- `./agent profile`,
- `./agent up <stack>` / `down` / `stack start|stop`,
- `./agent <tool> [project]`,
- `./agent ls`, `status`, `ps`, `logs`, `start`, `stop`,
- `./agent update`,
- `./agent rollback all <release_id>`,
- `./agent doctor`,
- `./agent backup run|list|restore`,
- `./agent onboard`,
- `./agent prereqs`,
- `./agent vm create|test|cleanup`,
- `./agent repo-e2e`,
- commandes spécialisées `ollama`, `trtllm`, `openclaw`, `strict-prod cleanup`, `rootless-dev cleanup`.

Par rapport au CDC source, le wrapper est plus ambitieux et plus central qu'initialement prévu. Il constitue déjà l'API opérateur de facto.

## 8. Mises à jour, traçabilité, rollback et sauvegarde

Le projet suit toujours la philosophie du CDC: images amont susceptibles d'évoluer rapidement, mais déploiement traçable.

Mécanisme actuel:

- `./agent update` résout les images actives,
- capture les digests réellement déployés,
- enregistre une release sous `${AGENTIC_ROOT}/deployments/releases/<release_id>/`,
- persiste la config Compose effective et un `runtime.env` sanitizé,
- met à jour `${AGENTIC_ROOT}/deployments/current`,
- permet `./agent rollback all <release_id>`.

Le dépôt va plus loin que le CDC initial en ajoutant:

- snapshots de backup incrémentaux via `./agent backup`,
- rollback du réseau hôte,
- rollback du lien de store Ollama,
- preuves VM pour campagne de validation `strict-prod`.

## 9. Sécurité et hardening

Le projet documente et applique un hardening pragmatique:

- conteneurs non-root quand possible,
- exceptions documentées quand une image upstream l'impose,
- rootfs en lecture seule quand compatible,
- montages explicites pour state/logs/workspaces,
- réduction des capacités Linux,
- `no-new-privileges`,
- secrets hors git,
- absence de montage Docker socket,
- loopback-only pour les UIs,
- journalisation des événements opératoires critiques.

Le comportement attendu n'est pas "isolement parfait", mais une réduction de surface crédible et vérifiable.

## 10. Conformité et preuve d'exploitation

Le CDC imposait un script de conformité. Le dépôt l'implémente avec `./agent doctor`.

Le périmètre contrôlé inclut notamment:

- binds loopback,
- absence de `docker.sock`,
- hardening des services sensibles,
- exceptions `read_only` documentées,
- présence des healthchecks,
- cohérence des volumes persistants,
- présence et qualité des artefacts de release,
- règles et secrets attendus autour du git forge,
- validations contextuelles liées à l'egress, au gate, à OpenClaw et aux agents.

L'écosystème de validation ne repose pas uniquement sur `doctor`. Il s'appuie aussi sur:

- tests shell dans `tests/`,
- bootstrap et diagnostics hôte,
- runbooks d'onboarding,
- campagne VM `strict-prod`.

## 11. État du projet par rapport au CDC source

### 11.1 Points désormais couverts

- architecture Compose découpée par plans,
- wrapper opérateur riche,
- profils `strict-prod` et `rootless-dev`,
- exposition locale stricte,
- persistance explicite sous `${AGENTIC_ROOT}`,
- observabilité baseline,
- OpenWebUI, OpenHands et ComfyUI intégrés,
- git forge interne convergé dans le flux baseline,
- OpenClaw intégré au socle,
- release snapshots et rollback opérables,
- diagnostics `doctor`,
- modules optionnels gouvernés,
- runbooks et ADR abondants.

### 11.2 Évolutions de périmètre par rapport au CDC initial

- `openclaw` est monté en `core`,
- Forgejo n'est plus un simple module secondaire,
- `gate-mcp`, `repo-e2e`, `backup`, `vm test` et `trtllm` ajoutent des capacités qui n'étaient pas formalisées dans le CDC source,
- la stack actuelle sert autant de plateforme de services que de banc d'essai agentique outillé.

### 11.3 Point de vigilance restant

Le dépôt documente lui-même une limite importante: le rollback est proche du déterminisme strict visé, mais pas encore totalement hermétique, car le mécanisme de restauration peut encore dépendre de fichiers Compose présents dans le working tree pour certaines releases. La direction cible est déjà identifiée dans la documentation technique: restauration depuis artefacts de snapshot uniquement, avec fallback legacy si nécessaire.

Ce point ne remet pas en cause l'utilité du mécanisme existant, mais il doit rester visible dans un CDC actualisé.

## 12. Définition de done actualisée

À l'échelle du dépôt actuel, une livraison conforme au CDC réécrit doit permettre, depuis un clone frais et après bootstrap approprié:

1. de choisir explicitement un profil et de connaître la vue runtime avec `./agent profile`,
2. de déployer le socle et les plans nécessaires avec `./agent up ...`,
3. de vérifier la conformité structurelle avec `./agent doctor`,
4. d'enregistrer une release traçable avec `./agent update`,
5. de revenir à une release antérieure avec `./agent rollback all <release_id>`,
6. d'opérer les agents CLI et UIs sans exposition publique,
7. d'auditer les écarts via logs, métriques, ADR et runbooks,
8. de garder les états persistants dans l'arborescence `${AGENTIC_ROOT}` prévue.

## 13. Références utiles dans le dépôt

Sources de vérité complémentaires:

- `README.fr.md`,
- `docs/runbooks/introduction.md`,
- `docs/runbooks/profiles.md`,
- `docs/runbooks/features-and-agents.md`,
- `docs/runbooks/host-layout.md`,
- `docs/runbooks/optional-modules.md`,
- `docs/runbooks/git-forge-management.md`,
- `docs/runbooks/images-developpement.md`,
- `docs/runbooks/implementation-strategy-refactoring.md`,
- `scripts/agent.sh`,
- `scripts/doctor.sh`,
- `compose/compose.core.yml`,
- `compose/compose.agents.yml`,
- `compose/compose.ui.yml`,
- `compose/compose.obs.yml`,
- `compose/compose.rag.yml`,
- `compose/compose.optional.yml`.

## 14. Résumé exécutif

Le CDC initial décrivait une stack DGX Spark agentique durcie, locale, traçable et opérable. Le dépôt actuel matérialise déjà cette vision sous une forme plus large et plus mature que le texte source: une plateforme par plans, gouvernée par `./agent`, contrôlée par `doctor`, documentée par ADR/runbooks, et enrichie de capacités additionnelles comme OpenClaw, Forgejo baseline, backups et validations VM.

Le bon usage de ce document n'est donc plus de décrire une intention abstraite, mais de servir de référence condensée entre le CDC historique et la réalité opérationnelle du repo.
