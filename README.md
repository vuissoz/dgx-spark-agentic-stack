# DGX Spark — Stack de services agentiques (implémentation du CDC)

Ce dépôt implémente une **stack de services agentiques conteneurisés** pour un **DGX Spark en usage single-user**, avec **mises à jour fréquentes** (`:latest`) mais **traçabilité + rollback stricts**, et un socle “sécurité/MCO raisonnable”. La solution **conserve explicitement** les services demandés : **Ollama + OpenHands + OpenWebUI + ComfyUI** (avec leurs UIs web), et ajoute les briques d’**egress control**, **observabilité**, **opérations** et **durcissement** décrites dans le cahier des charges. :contentReference[oaicite:0]{index=0}

> Hypothèse centrale : plateforme expérimentale mais maîtrisée. On cherche la **réduction de surface**, la **limitation d’impact**, et la **détection** (pas la “prévention parfaite”). :contentReference[oaicite:1]{index=1}

---

## Profils d’exécution

Le dépôt supporte deux profils explicites via `AGENTIC_PROFILE` :

- `strict-prod` (défaut) :
  - cible CDC stricte ;
  - runtime dans `/srv/agentic` ;
  - contrôles `DOCKER-USER` requis.
- `rootless-dev` :
  - développement local sans droits root sur l’hôte principal ;
  - runtime dans `${HOME}/.local/share/agentic` (par défaut) ;
  - checks host-root-only dégradés en warning dans `agent doctor`.

Commande de diagnostic profil :

```bash
./agent profile
```

---

## Ce que la stack garantit (principes non négociables)

- **Un seul backend LLM partagé** : Ollama, consommé via un **point de contrôle** (`ollama-gate`) pour éviter le chaos multi-clients (queue/priorités/sticky model). :contentReference[oaicite:2]{index=2}  
- **Aucune UI exposée publiquement** : tous les ports web sont **bindés sur `127.0.0.1`** ; l’accès distant se fait **uniquement via Tailscale/SSH côté hôte** (pas de Tailscale dans les conteneurs). :contentReference[oaicite:3]{index=3}  
- **Sortie web gouvernée** : trafic HTTP(S) sortant via **un proxy egress central** + **enforcement `DOCKER-USER`** pour empêcher le bypass. :contentReference[oaicite:4]{index=4}  
- **Agents CLI “long-run”** : sessions persistantes **tmux**, accessibles via **une seule commande `agent`** sur l’hôte (masque Docker/Compose). :contentReference[oaicite:5]{index=5}  
- **Durcissement par défaut** : non-root, `cap_drop: ALL`, `no-new-privileges`, FS read-only hors workspaces/state/logs, `tmpfs /tmp`, limites de ressources (pids/ulimits). :contentReference[oaicite:6]{index=6}  
- **Update/rollback reproductibles** : capture des **digests**, snapshot de déploiement, rollback par digest. :contentReference[oaicite:7]{index=7}  

---

## Services inclus

### Obligatoires (socle)
- **Ollama** (serveur LLM local) — bind `127.0.0.1:11434` ; modèles dans `/srv/agentic/ollama/`. :contentReference[oaicite:8]{index=8}  
- **ollama-gate** (scheduler/queue/politiques d’accès à Ollama) — interne Docker (ex. `:11435`), logs JSON, sticky model. :contentReference[oaicite:9]{index=9}  
- **DNS interne** (Unbound) — pour éviter DNS “libre” depuis les conteneurs. :contentReference[oaicite:10]{index=10}  
- **Proxy egress** (Squid/Tinyproxy) — sortie HTTP(S), allowlist/denylist + logs. :contentReference[oaicite:11]{index=11}  
- **Agents CLI** : `claude`, `codex`, `opencode` (conteneurs always-on, sessions tmux, pas d’UI web). :contentReference[oaicite:12]{index=12}  
- **Observabilité** : Prometheus + Grafana + Loki + exporters + **DCGM exporter** (GPU). :contentReference[oaicite:13]{index=13}  

### Demandés (UI)
- **OpenWebUI** — chat web sur Ollama via `ollama-gate`, bind `127.0.0.1:8080`. :contentReference[oaicite:14]{index=14}  
- **OpenHands** — agent coding web, bind `127.0.0.1:3000` (durci, pas de docker.sock direct). :contentReference[oaicite:15]{index=15}  
- **ComfyUI** — génération d’images, bind `127.0.0.1:8188`, modèles volumineux. :contentReference[oaicite:16]{index=16}  

### Recommandé
- **RAG baseline** : Qdrant + embeddings via Ollama (toujours via `ollama-gate`). :contentReference[oaicite:17]{index=17}  

### Optionnels (à activer explicitement, risques plus élevés)
- **Mistral Vibe** (CLI) — alternatif “terminal-first”. :contentReference[oaicite:18]{index=18}  
- **Clawdbot** (notifications DM contrôlées) — token runtime + allowlist + audit logs.
- **MCP Catalog** (catalogue d’outils restreint) — allowlist stricte + audit logs.
- **Portainer** (inspection locale) — bind loopback-only, sans montage `docker.sock`.

---

## Architecture Compose (profils)

La stack est découpée en plusieurs fichiers Compose, avec **un réseau Docker privé unique**.

- `compose.core.yml` : ollama, ollama-gate, unbound, egress-proxy  
- `compose.agents.yml` : agents CLI (claude/codex/opencode/option vibe)  
- `compose.ui.yml` : openwebui, openhands, comfyui  
- `compose.obs.yml` : prometheus, grafana, loki, exporters, dcgm-exporter  
- `compose.optional.yml` : `optional-sentinel` + modules K (`clawdbot`, `mcp`, `portainer`) activés explicitement via profils.

---

## Arborescence hôte (contrat de persistance)

Racine runtime selon profil :
- `strict-prod` : `/srv/agentic/`
- `rootless-dev` : `${HOME}/.local/share/agentic/`

Le layout reste identique dans les deux cas. :contentReference[oaicite:21]{index=21}

/srv/agentic/
ollama/
gate/{state,logs}/
proxy/{config,logs}/
dns/unbound/
openwebui/
openhands/
comfyui/{models,input,output,user}/
rag/{qdrant,qdrant-snapshots,docs}/
claude/{state,logs,workspaces}/
codex/{state,logs,workspaces}/
opencode/{state,logs,workspaces}/
vibe/{state,logs,workspaces}/ # si activé
deployments/{compose,snapshots,incidents,policy}/
secrets/{runtime,rotation.log}/
shared-ro/
shared-rw/

Règles pratiques :
- **pas de secrets** dans les workspaces,
- **permissions strictes** (pas world-readable),
- **workspaces par projet et par tool** (blast radius réduit). :contentReference[oaicite:22]{index=22}  

---

## Pré-requis

- Linux (Ubuntu / DGX OS)
- Docker Engine + Docker Compose v2
- NVIDIA Container Toolkit opérationnel
- Stockage NVMe suffisant (LLM + ComfyUI = dizaines à centaines de Go)
- `iptables` disponible (enforcement `DOCKER-USER`) :contentReference[oaicite:23]{index=23}  

---

## Démarrage rapide

### 1) Cloner
git clone dgx-agentic-stack
cd dgx-agentic-stack

### 2) Bootstrap hôte (crée `<AGENTIC_ROOT>`, permissions, configs de base)
> Le repo fournit un script de bootstrap (à adapter à votre politique système).

Mode strict-prod :
export AGENTIC_PROFILE=strict-prod
sudo ./scripts/bootstrap-host.sh

Mode rootless-dev :
export AGENTIC_PROFILE=rootless-dev
./scripts/bootstrap-host.sh

### 3) Déployer le socle
sudo docker compose -f deploy/compose/compose.core.yml up -d
sudo docker compose -f deploy/compose/compose.agents.yml up -d
sudo docker compose -f deploy/compose/compose.obs.yml up -d
sudo docker compose -f deploy/compose/compose.ui.yml up -d

### 4) Vérifier la conformité (“doctor”)
sudo ./agent doctor

---

## Usage quotidien (commande `agent`)

La commande `agent` est l’API opérateur : elle masque Docker/Compose et standardise l’UX. :contentReference[oaicite:24]{index=24}  

Exemples :
agent profile
agent claude
agent codex
agent opencode
agent ls
agent logs claude
agent stop openwebui
agent net apply
agent ollama-link # crée/maintient le lien symbolique local des modèles (rootless-dev)
agent ollama-preload # preload en RW puis remonte en RO (budget 12GB par défaut)
agent ollama-models rw
agent ollama-models ro
agent update
agent rollback all
agent rollback host-net <backup_id>
agent rollback ollama-link <backup_id|latest>
AGENTIC_OPTIONAL_MODULES=clawdbot agent up optional
AGENTIC_OPTIONAL_MODULES=mcp,portainer agent up optional

Recommandé :
agent project [--tool claude] [--model ]
agent model show
agent model switch
agent clean # destructif, confirmation obligatoire

---

## Sécurité (résumé opérable)

### Exposition réseau
- **Interdit** : bind `0.0.0.0`
- **Autorisé** : bind `127.0.0.1` uniquement
- Accès distant : **SSH tunnel** ou **Tailscale côté hôte** (pas dans les conteneurs) :contentReference[oaicite:25]{index=25}  

### Egress control
- HTTP(S) sortant via **egress-proxy**
- Bypass empêché par **règles `DOCKER-USER`** (DROP + LOG) :contentReference[oaicite:26]{index=26}  

### Conteneurs agents CLI
- non-root, caps drop, no-new-privileges
- FS read-only (hors `/workspaces`, `/state`, `/logs`)
- `tmpfs /tmp`, limites pids/ulimits
- pas de docker.sock :contentReference[oaicite:27]{index=27}  

### Prompt injection (pragmatique)
- contenu web/externes traité comme **non fiable** (tag “untrusted” côté prompts)
- logs des sources (URL/hash) au niveau projet
- commandes “à risque” : confirmation renforcée + journalisation :contentReference[oaicite:28]{index=28}  

---

## Mises à jour & rollback (discipline “:latest mais traçable”)

La procédure `agent update` doit :
- pull des images,
- capturer les **digests réels**,
- écrire un snapshot : `digests.json`, compose effectifs, rapport de healthchecks,
- redéployer,
- valider la santé post-update. :contentReference[oaicite:29]{index=29}  

Rollback :
agent rollback all
=> ré-déploie **exactement** les digests du snapshot. :contentReference[oaicite:30]{index=30}  

---

## Observabilité

Exemples de signaux attendus :
- GPU : util/VRAM (DCGM)
- `ollama-gate` : queue_depth, deny_count, p95_latency
- proxy : allow/deny, domaines, volumes
- DOCKER-USER : drops rate-limited
- disque : pente de croissance logs/models + alertes > 85% :contentReference[oaicite:31]{index=31}  

---

## Tests & conformité

Le dépôt doit fournir un test automatisé type `agent doctor` qui échoue si :
- un port est exposé sur `0.0.0.0`,
- la chaîne `DOCKER-USER` ne bloque pas le bypass,
- un agent a un egress direct sans proxy,
- un agent tourne en root / sans `no-new-privileges` / sans `cap_drop: ALL`,
- les services critiques ne sont pas healthy,
- aucun snapshot digest n’existe pour le déploiement actif. :contentReference[oaicite:32]{index=32}  

---

## Structure du dépôt (recommandée)

.
├── agent # CLI opérateur (wrapper)
├── deploy/
│ ├── compose/ # compose.*.yml (core/ui/agents/obs/optional)
│ ├── firewall/ # templates iptables DOCKER-USER
│ └── policy/ # allowlist registries, blocked images, etc.
├── scripts/
│ ├── bootstrap-host.sh
│ ├── doctor.sh # logique de conformité (appelée par agent doctor)
│ ├── update.sh # snapshots + digests + scan optionnel
│ └── backup.sh / restore.sh
├── docs/
│ ├── CDC.md # version lisible du CDC + décisions
│ ├── runbooks.md # IR/ops (ports exposés, bypass egress, UI compromise…)
│ └── hardening.md # baseline compose + exceptions documentées
└── LICENSE

---

## Contribution (règles simples)

Les PR qui changent la stack doivent :
- garder le bind `127.0.0.1` pour toute UI,
- préserver l’egress via proxy + enforcement DOCKER-USER,
- documenter toute exception de hardening (root, capabilities, ports, volumes),
- mettre à jour `agent doctor` si une règle structurante change. :contentReference[oaicite:33]{index=33}  

---

## Référence

- Cahier des charges : **CDC3_Agents_DGX_spark.docx** (source de vérité fonctionnelle et sécuritaire). :contentReference[oaicite:34]{index=34}  
