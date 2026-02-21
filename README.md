# DGX Spark Agentic Stack

Ce dépôt fournit une stack de services agentiques conteneurisés pour DGX Spark, avec:
- exposition locale uniquement (binds `127.0.0.1`),
- contrôle egress (proxy + DOCKER-USER en `strict-prod`),
- durcissement de base (`read_only`, `cap_drop: ALL`, `no-new-privileges`),
- snapshots de release + rollback,
- orchestration via une seule commande: `./agent`.

## Stacks Compose

Les fichiers Compose sont dans `compose/`:
- `compose/compose.core.yml`: `ollama`, `ollama-gate`, `gate-mcp`, `trtllm` (profile `trt`), `unbound`, `egress-proxy`, `toolbox`
- `compose/compose.agents.yml`: `agentic-claude`, `agentic-codex`, `agentic-opencode`
- `compose/compose.ui.yml`: `openwebui`, `openhands`, `comfyui`
- `compose/compose.obs.yml`: `prometheus`, `grafana`, `loki`, exporters
- `compose/compose.rag.yml`: `qdrant`
- `compose/compose.optional.yml`: `optional-sentinel`, `optional-openclaw`, `optional-openclaw-sandbox`, `optional-mcp-catalog`, `optional-pi-mono`, `optional-goose`, `optional-portainer`

## Profils d'exécution

Le profil est piloté par `AGENTIC_PROFILE`:
- `strict-prod` (défaut): runtime sous `/srv/agentic`, contrôles host `DOCKER-USER` actifs.
- `rootless-dev`: runtime sous `${HOME}/.local/share/agentic`, checks host root-only dégradés.

Vérification:

```bash
./agent profile
```

Activation optionnelle du backend TRT-LLM (interne uniquement):

```bash
export COMPOSE_PROFILES=trt
./agent up core
```

Le routage modèle -> backend reste centralisé dans `ollama-gate` via `${AGENTIC_ROOT}/gate/config/model_routes.yml`.

## Arborescence runtime (résumé)

Racine runtime:
- `strict-prod`: `/srv/agentic`
- `rootless-dev`: `${HOME}/.local/share/agentic`

Dossiers persistants clés:
- `ollama/`
- `gate/{config,state,logs,mcp/{state,logs}}/`
- `trtllm/{models,state,logs}/`
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

## Variables de chemins hôte (montages)

Les montages hôte utilisés par la stack sont paramétrables via variables d'environnement.
Les chemins persistants applicatifs restent sous `${AGENTIC_ROOT}`.

Pour l'observabilité (montages host telemetry), variables disponibles:
- `PROMTAIL_DOCKER_CONTAINERS_HOST_PATH` (défaut: `/var/lib/docker/containers`)
- `PROMTAIL_HOST_LOG_PATH` (défaut: `/var/log`)
- `NODE_EXPORTER_HOST_ROOT_PATH` (défaut: `/`)
- `CADVISOR_HOST_ROOT_PATH` (défaut: `/`)
- `CADVISOR_DOCKER_LIB_HOST_PATH` (défaut: `/var/lib/docker`)
- `CADVISOR_SYS_HOST_PATH` (défaut: `/sys`)
- `CADVISOR_DEV_DISK_HOST_PATH` (défaut: `/dev/disk`)

Exemple d'override avant démarrage:

```bash
export AGENTIC_PROFILE=rootless-dev
export PROMTAIL_HOST_LOG_PATH=/var/log
export NODE_EXPORTER_HOST_ROOT_PATH=/
./agent profile
./agent up obs
```

`./agent profile` affiche les valeurs effectives utilisées.

## Override de l'image de base des agents (E1b)

Les services agents (`agentic-claude`, `agentic-codex`, `agentic-opencode`) partagent une image commune configurable à runtime.

Variables supportées:
- `AGENTIC_AGENT_BASE_IMAGE` (défaut: `agentic/agent-cli-base:local`)
- `AGENTIC_AGENT_BASE_BUILD_CONTEXT` (défaut: racine du repo)
- `AGENTIC_AGENT_BASE_DOCKERFILE` (défaut: `deployments/images/agent-cli-base/Dockerfile`)

Contrat minimal du Dockerfile custom:
- utilisateur par défaut non-root,
- `ENTRYPOINT` présent et compatible session tmux persistante,
- outils de base disponibles: `bash`, `tmux`, `git`, `curl`.

Exemple:

```bash
export AGENTIC_AGENT_BASE_IMAGE=agentic/agent-cli-base:custom
export AGENTIC_AGENT_BASE_BUILD_CONTEXT=/opt/agent-images/custom-base
export AGENTIC_AGENT_BASE_DOCKERFILE=/opt/agent-images/custom-base/Dockerfile
./agent up agents
```

Les valeurs effectives sont visibles via `./agent profile` et persistées dans `${AGENTIC_ROOT}/deployments/runtime.env`.

## Prérequis

- Linux + Docker Engine
- Docker Compose v2 (`docker compose`)
- Multipass (`multipass`) pour les commandes VM (`agent vm create`, `agent vm test`)
- NVIDIA Container Toolkit (pour services GPU)
- `iptables` disponible (en `strict-prod` pour `DOCKER-USER`)
- `acl` / `setfacl` recommandé en `rootless-dev` (ACL des logs Squid)

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
- `18111` → OpenClaw webhook ingress optionnel (`http://127.0.0.1:18111`)

Notes:
- tunneliser uniquement les ports nécessaires;
- les ports host sont configurables via variables d'environnement (`*_HOST_PORT`) ;
- `qdrant` n'est pas publié sur un port host dans la config actuelle.
- `optional-openclaw` publie uniquement un ingress webhook local (`127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`), jamais en `0.0.0.0`.

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
agent stack <start|stop> <core|agents|ui|obs|rag|optional|all>
agent <claude|codex|opencode> [project]
agent ls
agent ps
agent llm mode [local|hybrid|remote]
agent logs <service>
agent stop <tool>
agent stop service <service...>
agent stop container <container...>
agent start service <service...>
agent start container <container...>
agent cleanup [--yes] [--backup|--no-backup]
agent net apply
agent ollama-link
agent ollama-preload [--generate-model <model>] [--embed-model <model>] [--budget-gb <int>] [--no-lock-ro]
agent ollama-models <rw|ro>
agent update
agent rollback all <release_id>
agent rollback host-net <backup_id>
agent rollback ollama-link <backup_id|latest>
agent onboard [--profile ... --root ... --compose-project ... --network ... --egress-network ... --ollama-models-dir ... --output ... --non-interactive]
agent vm create [--name ... --cpus ... --memory ... --disk ... --image ... --reuse-existing --mount-repo|--no-mount-repo --require-gpu --skip-bootstrap --dry-run]
agent vm test [--name ... --workspace-path ... --test-selectors ... --require-gpu|--allow-no-gpu --dry-run]
agent test <A|B|C|D|E|F|G|H|I|J|K|L|V|all>
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

## Routage LLM externe (D5)

`ollama-gate` peut router des modèles vers `openai`/`openrouter` tout en gardant l'API client stable (`/v1/*`).

Prérequis runtime:
- clés API hors git:
  - `${AGENTIC_ROOT}/secrets/runtime/openai.api_key`
  - `${AGENTIC_ROOT}/secrets/runtime/openrouter.api_key`
- egress allowlist explicite:
  - `${AGENTIC_ROOT}/proxy/allowlist.txt` doit contenir `api.openai.com` et `openrouter.ai`

## Modes LLM + quotas externes (D6)

- `./agent llm mode local` : bloque explicitement les providers externes.
- `./agent llm mode hybrid` : local prioritaire + externe selon routage.
- `./agent llm mode remote` : providers externes autorisés (et possibilité d'arrêter `ollama`/`trtllm` pour libérer GPU/RAM).

Exemple mode `remote` avec pause locale:

```bash
./agent llm mode remote
./agent stop service ollama trtllm
```

State runtime:
- mode: `${AGENTIC_ROOT}/gate/state/llm_mode.json`
- compteurs quotas: `${AGENTIC_ROOT}/gate/state/quotas_state.json`
- métriques: `external_requests_total`, `external_tokens_total`, `external_quota_remaining`

## MCP local `gate-mcp` (D7)

Le service `gate-mcp` est inclus dans `core` et reste interne (aucun port hôte publié).  
Il expose `/v1/tools/execute` avec:
- `gate.current_model`
- `gate.quota_remaining`
- `gate.switch_model`

Durcissement D7:
- auth locale obligatoire (`Authorization: Bearer ...`) via `${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token`
- rate limiting minimal côté service
- audit JSONL: `${AGENTIC_ROOT}/gate/mcp/logs/audit.jsonl`

Variables injectées dans les conteneurs agents:
- `GATE_MCP_URL=http://gate-mcp:8123`
- `GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token`

## Modules optionnels

Activation explicite:

```bash
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
AGENTIC_OPTIONAL_MODULES=mcp,pi-mono,goose,portainer ./agent up optional
```

Préconditions (runtime):
- fichiers de demande: `${AGENTIC_ROOT}/deployments/optional/*.request`
  - `${AGENTIC_ROOT}/deployments/optional/openclaw.request`
  - `${AGENTIC_ROOT}/deployments/optional/mcp.request`
  - `${AGENTIC_ROOT}/deployments/optional/pi-mono.request`
  - `${AGENTIC_ROOT}/deployments/optional/goose.request`
  - `${AGENTIC_ROOT}/deployments/optional/portainer.request`
- secrets:
  - `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`
  - `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`
  - `${AGENTIC_ROOT}/secrets/runtime/mcp.token`

## Validation

- Diagnostic global: `./agent doctor`
- Campagnes de tests: `./agent test <A..L|V|all>`
- Campagne VM `strict-prod` (preuves + update/rollback + tests): `./agent vm test --name agentic-strict-prod`
- Vérifier l'état de la VM: `multipass list` puis `multipass info <vm-name>` (`State: Running` attendu)

## Documentation détaillée

- Introduction (philosophie de la stack et modèle d'exploitation):
  - `docs/runbooks/introduction.md`
- Guide pas à pas (première installation complète):
  - `docs/runbooks/first-time-setup.md`
- VM dédiée `strict-prod` (validation prod-like):
  - `docs/runbooks/strict-prod-vm.md`
- Catalogue des fonctionnalités et des agents implémentés:
  - `docs/runbooks/features-and-agents.md`
- Guide pédagogique service par service (niveau débutant):
  - `docs/runbooks/services-expliques-debutants.md`
- Guide service par service en anglais (version beginner):
  - `docs/runbooks/services-explained-beginners.en.md`
- Onboarding ultra-simplifié non-tech (FR/EN/DE/IT):
  - `docs/runbooks/onboarding-ultra-simple.fr.md`
  - `docs/runbooks/onboarding-ultra-simple.en.md`
  - `docs/runbooks/onboarding-ultra-simple.de.md`
  - `docs/runbooks/onboarding-ultra-simple.it.md`
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
