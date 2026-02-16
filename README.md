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
- `compose/compose.optional.yml`: `optional-sentinel`, `optional-clawdbot`, `optional-mcp-catalog`, `optional-portainer`

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
- `optional/{clawdbot,mcp,portainer}/...`
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
AGENTIC_OPTIONAL_MODULES=clawdbot ./agent up optional
AGENTIC_OPTIONAL_MODULES=mcp,portainer ./agent up optional
```

Préconditions (runtime):
- fichiers de demande: `${AGENTIC_ROOT}/deployments/optional/*.request`
- secrets:
  - `${AGENTIC_ROOT}/secrets/runtime/clawdbot.token`
  - `${AGENTIC_ROOT}/secrets/runtime/mcp.token`

## Validation

- Diagnostic global: `./agent doctor`
- Campagnes de tests: `./agent test <A..K|all>`

## Références internes

- `AGENTS.md`
- `PLAN.md`
- `docs/runbooks/*.md`
- `docs/decisions/*.md`
