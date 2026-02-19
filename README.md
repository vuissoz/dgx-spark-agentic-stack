# DGX Spark Agentic Stack

Ce dépôt fournit une stack de services agentiques conteneurisés pour DGX Spark, avec:
- exposition locale uniquement (binds `127.0.0.1`),
- contrôle egress (proxy + DOCKER-USER en `strict-prod`),
- durcissement de base (`read_only`, `cap_drop: ALL`, `no-new-privileges`),
- snapshots de release + rollback,
- orchestration via une seule commande: `./agent`.

## Stacks Compose

Les fichiers Compose sont dans `compose/`:
- `compose/compose.core.yml`: `ollama`, `ollama-gate`, `unbound`, `egress-proxy`, `toolbox`
- `compose/compose.agents.yml`: `agentic-claude`, `agentic-codex`, `agentic-opencode`
- `compose/compose.ui.yml`: `openwebui`, `openhands`, `comfyui`
- `compose/compose.obs.yml`: `prometheus`, `grafana`, `loki`, exporters
- `compose/compose.rag.yml`: `qdrant`
- `compose/compose.optional.yml`: `optional-sentinel`, `optional-openclaw`, `optional-mcp-catalog`, `optional-pi-mono`, `optional-goose`, `optional-portainer`

## Profils d'exécution

Le profil est piloté par `AGENTIC_PROFILE`:
- `strict-prod` (défaut): runtime sous `/srv/agentic`, contrôles host `DOCKER-USER` actifs.
- `rootless-dev`: runtime sous `${HOME}/.local/share/agentic`, checks host root-only dégradés.

Vérification:

```bash
./agent profile
```

## Arborescence runtime (résumé)

Racine runtime:
- `strict-prod`: `/srv/agentic`
- `rootless-dev`: `${HOME}/.local/share/agentic`

Dossiers persistants clés:
- `ollama/`
- `gate/{state,logs}/`
- `proxy/{config,logs}/`
- `dns/`
- `openwebui/`
- `openhands/{config,state,logs,workspaces}/`
- `comfyui/{models,input,output,user}/`
- `rag/{qdrant,qdrant-snapshots,docs,scripts}/`
- `{claude,codex,opencode}/{state,logs,workspaces}/`
- `optional/{openclaw,mcp,pi-mono,goose,portainer}/...`
- `deployments/{releases,current}/`
- `secrets/`
- `shared-ro/`, `shared-rw/`

## Prérequis

- Linux + Docker Engine
- Docker Compose v2 (`docker compose`)
- NVIDIA Container Toolkit (pour services GPU)
- `iptables` disponible (en `strict-prod` pour `DOCKER-USER`)

## Démarrage rapide

### `strict-prod`

```bash
export AGENTIC_PROFILE=strict-prod
sudo ./deployments/bootstrap/init_fs.sh
sudo ./agent up core
sudo ./agent up agents,ui,obs,rag
sudo ./agent doctor
```

### `rootless-dev`

```bash
export AGENTIC_PROFILE=rootless-dev
./deployments/bootstrap/init_fs.sh
./agent ollama-link
./agent up core
./agent up agents,ui,obs,rag
./agent doctor
```

## Accès distant (Tailscale + tunnel SSH)

Les services sont bindés en `127.0.0.1` sur l'hôte.  
Conséquence: depuis un autre poste (même sur le réseau Tailscale), `http://<ip-tailscale-hote>:8080` ne fonctionne pas directement.

Le mode d'accès attendu est un tunnel SSH depuis le client vers l'hôte DGX:

```bash
ssh -N \
  -L 8080:127.0.0.1:8080 \
  -L 3000:127.0.0.1:3000 \
  -L 8188:127.0.0.1:8188 \
  -L 13000:127.0.0.1:13000 \
  -L 19090:127.0.0.1:19090 \
  -L 13100:127.0.0.1:13100 \
  <user>@<hostname-ou-ip-tailscale>
```

Ensuite, sur le poste client, ouvrir:
- `http://127.0.0.1:8080` (OpenWebUI)
- `http://127.0.0.1:3000` (OpenHands)
- `http://127.0.0.1:8188` (ComfyUI)
- `http://127.0.0.1:13000` (Grafana)
- `http://127.0.0.1:19090` (Prometheus)
- `http://127.0.0.1:13100` (Loki)

Ports utiles à tunneliser (selon les modules activés):
- `11434` → Ollama API (`http://127.0.0.1:11434`)
- `8080` → OpenWebUI (`http://127.0.0.1:8080`)
- `3000` → OpenHands (`http://127.0.0.1:3000`)
- `8188` → ComfyUI (`http://127.0.0.1:8188`)
- `13000` → Grafana (`http://127.0.0.1:13000`)
- `19090` → Prometheus (`http://127.0.0.1:19090`)
- `13100` → Loki (`http://127.0.0.1:13100`)
- `9001` → Portainer optionnel (`http://127.0.0.1:9001`)

Notes:
- tunneliser uniquement les ports nécessaires;
- les ports host sont configurables via variables d'environnement (`*_HOST_PORT`) ;
- `qdrant` n'est pas publié sur un port host dans la config actuelle.
- `optional-openclaw` de ce dépôt n'expose pas de port host (service interne Docker uniquement).

Comportement OpenClaw (upstream) si vous déployez la gateway officielle:
- gateway: `18789` (control plane + HTTP APIs + Control UI + WebSocket RPC sur un seul port),
- browser control service: `18791` (`gateway.port + 2`),
- relay: `18792` (`gateway.port + 3`),
- CDP local (profils managed browser): `18800-18899` par défaut.

Point de confusion fréquent:
- un nœud (`openclaw node run`) se connecte en sortie vers la gateway (WebSocket) et n'impose pas un nouveau port inbound côté gateway.

Vérification rapide (hôte Linux/macOS):

```bash
lsof -nP -iTCP -sTCP:LISTEN | egrep ':(18789|18791|18792|188[0-9]{2})'
ss -lntp | egrep ':(18789|18791|18792|188[0-9]{2})'
```

### iPhone

Oui, c'est possible avec une app SSH iOS qui supporte le port forwarding local (par ex. Termius, Blink Shell, Prompt).  
Principe identique: créer un tunnel local vers `127.0.0.1:<port>` de l'hôte, puis ouvrir `http://127.0.0.1:<port>` depuis l'iPhone (Safari ou navigateur intégré selon l'app).

## Commandes `agent`

Commandes supportées:

```text
agent profile
agent up <core|agents|ui|obs|rag|optional>
agent down <core|agents|ui|obs|rag|optional>
agent <claude|codex|opencode> [project]
agent ls
agent ps
agent logs <service>
agent stop <tool>
agent net apply
agent ollama-link
agent ollama-preload [--generate-model <model>] [--embed-model <model>] [--budget-gb <int>] [--no-lock-ro]
agent ollama-models <rw|ro>
agent update
agent rollback all <release_id>
agent rollback host-net <backup_id>
agent rollback ollama-link <backup_id|latest>
agent test <A|B|C|D|E|F|G|H|I|J|K|all>
agent doctor [--fix-net]
```

Exemples:

```bash
./agent up core
./agent up agents,ui
./agent codex my-project
./agent logs ollama
./agent stop codex
./agent update
./agent rollback all <release_id>
```

Notes:
- `agent stop` ne gère que les tools `claude|codex|opencode`.
- `agent rollback all` exige un `release_id`.

## Ollama: preload et lien de modèles

En `rootless-dev`, le lien symbolique local des modèles est géré via:

```bash
./agent ollama-link
```

Préchargement puis passage RO pour smoke tests:

```bash
./agent ollama-preload
./agent ollama-models ro
./agent ollama-models rw
```

Rollback du lien:

```bash
./agent rollback ollama-link <backup_id|latest>
```

## Modules optionnels

Activation explicite:

```bash
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
AGENTIC_OPTIONAL_MODULES=mcp,pi-mono,goose,portainer ./agent up optional
```

Préconditions (runtime):
- fichiers de demande: `${AGENTIC_ROOT}/deployments/optional/*.request`
  - `${AGENTIC_ROOT}/deployments/optional/pi-mono.request`
  - `${AGENTIC_ROOT}/deployments/optional/goose.request`
- secrets:
  - `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`
  - `${AGENTIC_ROOT}/secrets/runtime/mcp.token`

## Validation

- Diagnostic global: `./agent doctor`
- Campagnes de tests: `./agent test <A..K|all>`

## Documentation détaillée

- Guide pas à pas (première installation complète):
  - `docs/runbooks/first-time-setup.md`
- Catalogue des fonctionnalités et des agents implémentés:
  - `docs/runbooks/features-and-agents.md`
- Profils d'exécution:
  - `docs/runbooks/profiles.md`
- Modules optionnels:
  - `docs/runbooks/optional-modules.md`
- Triage observabilité (latence, erreurs egress, restarts, OOM):
  - `docs/runbooks/observability-triage.md`
- Modèle de sécurité OpenClaw (sandbox + egress contrôlé, sans `docker.sock`):
  - `docs/security/openclaw-sandbox-egress.md`

## Références internes

- `AGENTS.md`
- `PLAN.md`
- `docs/runbooks/*.md`
- `docs/decisions/*.md`
