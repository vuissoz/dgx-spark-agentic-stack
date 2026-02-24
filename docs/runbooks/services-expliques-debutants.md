# Runbook: Comprendre la Stack Service par Service (Version Debutant)

Ce document est volontairement pedagogique.
Il explique, service par service, ce que fait la stack DGX Spark Agentic, avec un vocabulaire simple.

Objectif:
- aider une personne non technicienne (ou technicien debutant) a comprendre "qui fait quoi",
- donner une carte mentale simple de l'architecture,
- fournir des liens officiels pour aller plus loin.

Ce document complete `docs/runbooks/introduction.md` (le "pourquoi") et `docs/runbooks/features-and-agents.md` (le "catalogue").
Version anglaise equivalente: `docs/runbooks/services-explained-beginners.en.md`.
Pour la configuration complete (variables, valeurs, stockage, secrets): `docs/runbooks/configuration-expliquee-debutants.md`.

## 1) Mini glossaire (bases utiles)

- Service: definition logique dans un fichier Compose (ex: `openwebui`).
- Conteneur: instance en cours d'execution d'un service (ex: `agentic-dev-openwebui-1`).
- Image: "modele" de conteneur (ex: `ghcr.io/open-webui/open-webui:latest`).
- Volume: dossier persistant (les donnees restent apres redemarrage du conteneur).
- Reseau Docker: "route interne" pour que les conteneurs se parlent entre eux.
- Healthcheck: test automatique qui dit "le service repond" ou "le service ne repond pas".
- Profile Compose: bouton d'activation (utile pour les modules optionnels).

Liens officiels utiles:
- Docker Compose (concept): https://docs.docker.com/get-started/docker-concepts/the-basics/what-is-docker-compose/
- Compose file reference: https://docs.docker.com/compose/compose-file/
- Profiles Compose: https://docs.docker.com/reference/compose-file/profiles/

## 2) Vue d'ensemble tres simple

La stack est divisee en 6 plans:

1. `core` (socle): modele IA + controle egress + DNS + outils de debug.
2. `agents` (execution): conteneurs de sessions agentiques (`claude`, `codex`, `opencode`, `vibestral`).
3. `ui` (interface): OpenWebUI, OpenHands, ComfyUI.
4. `obs` (observabilite): Prometheus, Grafana, Loki, exporters.
5. `rag` (recherche vectorielle): Qdrant.
6. `optional` (extensions): modules opt-in (OpenClaw, MCP catalog, Goose, Portainer, etc.).

Important securite:
- Les ports hote sont publies sur `127.0.0.1` (loopback) uniquement.
- Donc pas d'exposition Internet directe.
- Acces distant attendu: tunnel SSH/Tailscale vers l'hote.

## 3) Plan `core` (socle)

### Service `ollama`

Role simple:
- C'est le "moteur de modeles" local.
- Il charge les modeles LLM et repond aux requetes de generation.

Ce que vous devez retenir:
- Si `ollama` est arrete, plus aucun outil base sur ces modeles ne peut repondre.
- C'est le coeur IA local de la plateforme.

Entrees/sorties:
- Port hote: `127.0.0.1:11434`.
- Volume persistant: dossier modeles Ollama sous `${AGENTIC_ROOT}/ollama/models` (ou lien rootless).

Liens officiels:
- Docs Ollama: https://docs.ollama.com/
- API Ollama: https://docs.ollama.com/api/introduction
- Repo officiel: https://github.com/ollama/ollama

### Service `ollama-gate`

Role simple:
- C'est un "sas" entre les applications et Ollama.
- Il normalise l'acces, limite la concurrence, gere une file d'attente et journalise les decisions.

Pourquoi il existe:
- Eviter que chaque application tape directement Ollama sans controle.
- Garder une gouvernance simple (timeouts, logs, sticky sessions, metriques).

Entrees/sorties:
- Pas d'exposition publique directe sur l'hote.
- Utilise par les autres services via le reseau Docker interne (`http://ollama-gate:11435`).
- Etat/logs persistants dans `${AGENTIC_ROOT}/gate/{state,logs}`.

Liens officiels (technos de base utilisees):
- FastAPI: https://fastapi.tiangolo.com/
- API Ollama (backend vise): https://docs.ollama.com/api/introduction

### Service `unbound`

Role simple:
- C'est le "DNS resolver" local de la stack.
- Il transforme les noms de domaine en IP, avec comportement controle.

Pourquoi il existe:
- Mieux maitriser la resolution DNS dans un schema egress contraint.
- Ici, "egress" veut dire le trafic sortant des conteneurs vers l'exterieur (Internet): DNS, HTTP, HTTPS, etc.
- "Contrainte" veut dire que ces sorties sont filtrees (proxy, allowlist, regles reseau) au lieu d'etre libres.

Entrees/sorties:
- Service interne (pas d'UI).
- Configuration depuis `${AGENTIC_ROOT}/dns/unbound.conf`.

Liens officiels:
- Documentation Unbound: https://unbound.docs.nlnetlabs.nl/
- Site projet NLnet Labs: https://www.nlnetlabs.nl/documentation/unbound/

### Service `egress-proxy`

Role simple:
- C'est le "portier de sortie web" (proxy HTTP/HTTPS sortant).
- Les services applicatifs passent par lui pour sortir vers Internet.

Pourquoi il existe:
- Appliquer une politique d'egress (allowlist, logs, audit).
- Eviter un acces sortant libre et non trace.

Entrees/sorties:
- Service interne (pas d'UI utilisateur finale).
- Config: `${AGENTIC_ROOT}/proxy/config/squid.conf` et `allowlist.txt`.
- Logs: `${AGENTIC_ROOT}/proxy/logs`.

Liens officiels:
- Site Squid: https://www.squid-cache.org/
- Documentation Squid: https://www.squid-cache.org/Doc/
- FAQ Squid: https://wiki.squid-cache.org/SquidFaq/index

### Service `toolbox`

Role simple:
- Boite a outils de diagnostic reseau (ping, drill, curl, tcpdump, etc.).
- Utilisee pour tests, debug et verification de politiques reseau.

Pourquoi il existe:
- Diagnostiquer sans "polluer" les conteneurs applicatifs.

Entrees/sorties:
- Pas d'UI.
- Conteneur utilitaire de support.

Liens officiels:
- Netshoot (image utilisee): https://github.com/nicolaka/netshoot

## 4) Plan `agents` (execution agentique)

Les 4 services ci-dessous partagent la meme logique:
- par defaut ils tournent avec `agentic/agent-cli-base:local` (override possible via `AGENTIC_AGENT_BASE_*`),
- ils utilisent `tmux` pour garder des sessions longues,
- ils ont chacun leurs dossiers `state/logs/workspaces` separes.
- l'image commune embarque les CLIs `codex`, `claude`, `opencode`, `vibe` (et aussi `openhands`, `openclaw` pour usages CLI transverses).

### Service `agentic-claude`

Role simple:
- Session agentique dediee a l'outil `claude`.

A retenir:
- Pensez "poste de travail conteneurise" persistant, pas "commande jetable".

Liens officiels:
- Claude Code (Anthropic): https://docs.anthropic.com/en/docs/claude-code/overview
- Setup Claude Code: https://docs.anthropic.com/en/docs/claude-code/setup
- tmux (base de session): https://github.com/tmux/tmux

### Service `agentic-codex`

Role simple:
- Session agentique dediee a l'outil `codex`.

A retenir:
- Meme mecanique que `agentic-claude`, mais outillage OpenAI/Codex.

Liens officiels:
- Codex CLI (OpenAI Help): https://help.openai.com/en/articles/11096431
- Repo officiel Codex: https://github.com/openai/codex
- OpenAI developer docs: https://platform.openai.com/docs
- tmux: https://github.com/tmux/tmux

### Service `agentic-opencode`

Role simple:
- Session agentique dediee a l'outil `opencode`.

A retenir:
- Meme architecture de confinement que les autres agents.

Liens officiels:
- OpenCode: https://opencode.ai/
- Docs CLI OpenCode: https://opencode.ai/docs/cli/
- tmux: https://github.com/tmux/tmux

### Service `agentic-vibestral`

Role simple:
- Session agentique dediee a l'outil `vibestral`.

A retenir:
- Meme modele de confinement et de persistance que les autres agents de base (`agentic-claude`, `agentic-codex`, `agentic-opencode`).

Liens utiles:
- tmux: https://github.com/tmux/tmux

## 5) Plan `ui` (interfaces utilisateur)

### Service `openwebui`

Role simple:
- Interface web "chat" pour utiliser des modeles via `ollama-gate`.

Pour debutant:
- C'est la "porte d'entree conversationnelle" la plus evidente.

Entrees/sorties:
- Port hote: `127.0.0.1:${OPENWEBUI_HOST_PORT:-8080}`.
- Donnees: `${AGENTIC_ROOT}/openwebui/data`.

Liens officiels:
- Open WebUI docs: https://docs.openwebui.com/
- Repo officiel: https://github.com/open-webui/open-webui

### Service `openhands`

Role simple:
- Interface agentique orientee "realiser des taches" (code/workflows) via LLM.

Pour debutant:
- OpenWebUI = conversation generaliste.
- OpenHands = execution agentique plus orientee action/projet.

Entrees/sorties:
- Port hote: `127.0.0.1:${OPENHANDS_HOST_PORT:-3000}`.
- Dossiers: `${AGENTIC_ROOT}/openhands/{state,logs,workspaces}`.
- `docker.sock` non monte (choix securite du stack).

Liens officiels:
- OpenHands docs: https://docs.openhands.dev/
- OpenHands usage CLI: https://docs.openhands.dev/openhands/usage/how-to/cli-mode

### Service `comfyui`

Role simple:
- Moteur/GUI node-based pour workflows generatifs (image/video selon modeles/plugins).

Pour debutant:
- C'est une "usine a pipelines visuels" IA (noeuds, liens, workflows).

Entrees/sorties:
- Service interne principal, avec stockage sur `${AGENTIC_ROOT}/comfyui/*`.
- Utilise GPU (`gpus: all`) avec profil low-priority dans cette stack.

Liens officiels:
- ComfyUI docs: https://docs.comfy.org/
- Repo officiel: https://github.com/Comfy-Org/ComfyUI

### Service `comfyui-loopback`

Role simple:
- Reverse proxy NGINX minimal qui publie ComfyUI sur loopback hote.

Pourquoi il existe:
- Isoler la publication du port hote tout en gardant ComfyUI en interne.

Entrees/sorties:
- Port hote: `127.0.0.1:${COMFYUI_HOST_PORT:-8188}`.

Liens officiels:
- NGINX docs: https://nginx.org/en/docs/
- Image `nginx-unprivileged`: https://hub.docker.com/r/nginxinc/nginx-unprivileged

## 6) Plan `obs` (observabilite)

### Service `prometheus`

Role simple:
- Collecte des metriques (CPU, memoire, etat services, etc.) en mode serie temporelle.

Pour debutant:
- C'est la "base de donnees des courbes".

Entrees/sorties:
- Port hote: `127.0.0.1:${PROMETHEUS_HOST_PORT:-19090}`.
- Donnees: `${AGENTIC_ROOT}/monitoring/prometheus`.

Liens officiels:
- Prometheus overview: https://prometheus.io/docs/introduction/overview/
- PromQL basics: https://prometheus.io/docs/prometheus/latest/querying/basics/

### Service `grafana`

Role simple:
- Tableau de bord et visualisation (metriques + logs).

Pour debutant:
- C'est l'"ecran cockpit" de la plateforme.

Entrees/sorties:
- Port hote: `127.0.0.1:${GRAFANA_HOST_PORT:-13000}`.
- Donnees: `${AGENTIC_ROOT}/monitoring/grafana`.

Liens officiels:
- Grafana get started: https://grafana.com/docs/grafana/latest/fundamentals/getting-started/

### Service `loki`

Role simple:
- Base de logs centralisee.

Pour debutant:
- Prometheus stocke des chiffres.
- Loki stocke des lignes de logs.

Entrees/sorties:
- Port hote: `127.0.0.1:${LOKI_HOST_PORT:-13100}`.
- Donnees: `${AGENTIC_ROOT}/monitoring/loki`.

Liens officiels:
- Loki docs: https://grafana.com/docs/loki/latest/
- Loki architecture: https://grafana.com/docs/loki/latest/fundamentals/architecture/

### Service `promtail`

Role simple:
- Agent qui lit des fichiers de logs et les envoie a Loki.

Point important:
- Promtail est en fin de vie a moyen terme (LTS/EOL), mais reste fonctionnel ici.

Liens officiels:
- Promtail docs: https://grafana.com/docs/loki/latest/send-data/promtail/
- Send data to Loki: https://grafana.com/docs/loki/latest/send-data/

### Service `node-exporter`

Role simple:
- Expose les metriques systeme hote (CPU, RAM, filesystem, etc.) pour Prometheus.

Liens officiels:
- Repo officiel: https://github.com/prometheus/node_exporter

### Service `cadvisor`

Role simple:
- Expose les metriques des conteneurs Docker (consommation ressources).

Liens officiels:
- Repo officiel: https://github.com/google/cadvisor

### Service `dcgm-exporter`

Role simple:
- Expose les metriques GPU NVIDIA pour Prometheus.

Liens officiels:
- Repo officiel: https://github.com/NVIDIA/dcgm-exporter
- Documentation NVIDIA (reference): https://docs.nvidia.com/datacenter/dcgm/latest/

## 7) Plan `rag` (stockage vectoriel)

### Service `qdrant`

Role simple:
- Base vectorielle pour la recherche semantique (RAG).

Pour debutant:
- On y stocke des "empreintes vectorielles" de documents.
- Cela permet de retrouver des passages pertinents avant generation LLM.

Entrees/sorties:
- Pas de port hote publie dans cette stack (service interne).
- Donnees: `${AGENTIC_ROOT}/rag/qdrant` et snapshots `${AGENTIC_ROOT}/rag/qdrant-snapshots`.

Liens officiels:
- Qdrant docs: https://qdrant.tech/documentation/
- Repo officiel: https://github.com/qdrant/qdrant

### Service `rag-retriever`

Role simple:
- API interne qui orchestre la recherche hybride:
  - dense (vectorielle via Qdrant),
  - lexicale (via OpenSearch si active),
  - fusion des resultats (`rrf`).

Entrees/sorties:
- Service interne uniquement (`rag-retriever:7111`), pas de port hote.
- Etat/logs: `${AGENTIC_ROOT}/rag/retriever/{state,logs}`.

### Service `rag-worker`

Role simple:
- Worker asynchrone qui indexe le corpus local pour la retrieval (`/v1/index`).

Entrees/sorties:
- Service interne uniquement (`rag-worker:7112`), pas de port hote.
- Etat/logs: `${AGENTIC_ROOT}/rag/worker/{state,logs}`.

### Service `opensearch` (profil `rag-lexical`, optionnel)

Role simple:
- Backend lexical (BM25) pour completer la recherche dense.

Entrees/sorties:
- Interne uniquement (`opensearch:9200`), pas de port hote.
- Donnees/logs: `${AGENTIC_ROOT}/rag/opensearch` et `${AGENTIC_ROOT}/rag/opensearch-logs`.

## 8) Plan `optional` (modules opt-in)

Important:
- Ces services ne sont pas necessairement actifs en permanence.
- Ils sont actives par `profiles` Compose + prerequis/secrets.

### Service `optional-sentinel`

Role simple:
- Conteneur sentinelle minimal pour valider l'activation du plan optionnel.

Liens officiels:
- Alpine image: https://hub.docker.com/_/alpine

### Service `optional-openclaw`

Role simple:
- Point d'entree OpenClaw (webhook/API locale selon configuration du stack).

A retenir:
- Dans ce repo, c'est un composant optionnel fortement encadre (secrets, allowlists, sandbox).

Liens:
- Documentation interne stack: `docs/security/openclaw-sandbox-egress.md`
- Concept MCP (utile pour comprendre certaines integrations): https://modelcontextprotocol.io/

### Service `optional-openclaw-sandbox`

Role simple:
- Sandbox d'execution associee a OpenClaw.

A retenir:
- Sert a limiter l'impact et separer l'execution des actions sensibles.

Liens:
- Documentation interne stack: `docs/security/openclaw-sandbox-egress.md`

### Service `optional-mcp-catalog`

Role simple:
- Service optionnel autour du catalogue/outils MCP.

Pour debutant:
- MCP est un standard pour connecter des outils externes a des agents IA.

Liens officiels:
- MCP introduction: https://modelcontextprotocol.io/
- MCP spec: https://modelcontextprotocol.io/specification/
- SDKs MCP: https://modelcontextprotocol.io/docs/sdk

### Service `optional-pi-mono`

Role simple:
- Session agentique optionnelle (meme famille que `agentic-*`).

Liens utiles:
- tmux: https://github.com/tmux/tmux

### Service `optional-goose`

Role simple:
- Agent optionnel Goose (mode conteneurise).

Liens officiels:
- Repo Goose: https://github.com/block/goose
- Docs Goose: https://block.github.io/goose/docs/

### Service `optional-portainer`

Role simple:
- UI d'administration de conteneurs (optionnelle) exposee en loopback.

Entrees/sorties:
- Port hote: `127.0.0.1:${PORTAINER_HOST_PORT:-9001}`.

Liens officiels:
- Portainer docs: https://docs.portainer.io/start/install-ce
- Setup initial Portainer: https://docs.portainer.io/start/install-ce/server/setup

## 9) Reseaux Docker de la stack

### Reseau `agentic`

Role simple:
- Reseau interne principal entre services.

A retenir:
- Certains plans le definissent en `internal: true` pour reduire l'exposition.

### Reseau `agentic-egress`

Role simple:
- Reseau de sortie controlee pour les services qui doivent faire de l'egress.

A retenir:
- Complete les variables proxy et les controles host (selon profile).

## 10) Comment lire l'etat "service par service" en pratique

Commandes utiles:

```bash
./agent ps
./agent ls
./agent logs <service>
./agent doctor
```

Ce qu'il faut verifier en premier:
- le service est-il `Up` ?
- le healthcheck est-il `healthy` ?
- le port est-il bien en `127.0.0.1` ?
- les volumes attendus existent-ils sous `${AGENTIC_ROOT}` ?

## 11) Resume ultra-court pour debuter

Si vous debutez, retenez cette phrase:
- "Ollama calcule, Ollama-gate controle, OpenWebUI/OpenHands affichent, Prometheus/Grafana/Loki observent, Qdrant retrouve, et les modules optional ajoutent des capacites sous conditions."

Puis l'ordre de lecture recommande:
1. `docs/runbooks/introduction.md`
2. `docs/runbooks/profiles.md`
3. `docs/runbooks/first-time-setup.md`
4. ce document (`docs/runbooks/services-expliques-debutants.md`)
5. `docs/runbooks/features-and-agents.md`
