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
- `compose/compose.agents.yml`: `agentic-claude`, `agentic-codex`, `agentic-opencode`, `agentic-vibestral`
- `compose/compose.ui.yml`: `openwebui`, `openhands`, `comfyui`
- `compose/compose.obs.yml`: `prometheus`, `grafana`, `loki`, exporters
- `compose/compose.rag.yml`: `qdrant`, `rag-retriever`, `rag-worker`, `opensearch` (profile `rag-lexical`)
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
Le modèle local par défaut est piloté par `AGENTIC_DEFAULT_MODEL` (fallback `llama3.1:8b`) et réutilisé pour le preload Ollama.

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
- `comfyui/{models,input,output,user,custom_nodes}/`
- `rag/{qdrant,qdrant-snapshots,docs,scripts,retriever/{state,logs},worker/{state,logs},opensearch,opensearch-logs}/`
- `{claude,codex,opencode,vibestral}/{state,logs,workspaces}/`
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

Les services agents (`agentic-claude`, `agentic-codex`, `agentic-opencode`, `agentic-vibestral`) partagent une image commune configurable à runtime.

Par défaut, `deployments/images/agent-cli-base/Dockerfile` construit une image de développement basée sur CUDA (NVIDIA) avec une toolchain multi-langages (C/C++, Python, Node, Go, Rust).

Cette image commune installe aussi les CLIs agents suivants: `codex`, `claude`, `opencode`, `vibe`, `openhands`, `openclaw`.
- mode par défaut: `AGENT_CLI_INSTALL_MODE=best-effort` (wrappers explicites si un install échoue),
- mode strict: `AGENT_CLI_INSTALL_MODE=required` (build en échec si un CLI manque).

Traçabilité build:
- `/etc/agentic/cli-install-status.tsv`
- `/etc/agentic/<cli>-real-path`

Variables supportées:
- `AGENTIC_AGENT_BASE_IMAGE` (défaut: `agentic/agent-cli-base:local`)
- `AGENTIC_AGENT_BASE_BUILD_CONTEXT` (défaut: racine du repo)
- `AGENTIC_AGENT_BASE_DOCKERFILE` (défaut: `deployments/images/agent-cli-base/Dockerfile`)
- `AGENTIC_AGENT_CLI_INSTALL_MODE` (`best-effort` par défaut, `required` pour un build strict)
- `AGENTIC_AGENT_NO_NEW_PRIVILEGES` (`true` par défaut; passer à `false` active le mode sudo intra-conteneur des agents)
- `AGENTIC_CODEX_CLI_NPM_SPEC`, `AGENTIC_CLAUDE_CODE_NPM_SPEC`, `AGENTIC_OPENCODE_NPM_SPEC`
- `AGENTIC_OPENHANDS_INSTALL_SCRIPT`, `AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT`, `AGENTIC_OPENCLAW_INSTALL_VERSION`, `AGENTIC_VIBE_INSTALL_SCRIPT`

Contrat minimal du Dockerfile custom:
- utilisateur par défaut non-root,
- `ENTRYPOINT` présent et compatible session tmux persistante,
- outils de base disponibles: `bash`, `tmux`, `git`, `curl`.

Le Dockerfile par défaut accepte aussi un build arg `AGENT_BASE_IMAGE` pour changer la base CUDA (tag/digest) tout en conservant le reste de la toolchain.

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
- Multipass (`multipass`) pour les commandes VM (`agent vm create`, `agent vm test`, `agent vm cleanup`)
- NVIDIA Container Toolkit (pour services GPU)
- `iptables` disponible (en `strict-prod` pour `DOCKER-USER`)
- `acl` / `setfacl` recommandé en `rootless-dev` (ACL des logs Squid)

Validation rapide des prérequis:

```bash
./agent prereqs
```

Note GPU: si votre environnement utilise un chemin CDI/driver spécifique, vous pouvez ajuster l'image de smoke test:
- `AGENTIC_NVIDIA_SMOKE_IMAGE` (défaut: `nvidia/cuda:12.2.0-base-ubuntu22.04`)

## Démarrage rapide

### `strict-prod`

```bash
export AGENTIC_PROFILE=strict-prod
sudo ./deployments/bootstrap/init_fs.sh
sudo ./agent up core
sudo ./agent up agents,ui,obs,rag
sudo ./agent doctor
```

Equivalent one-shot command:

```bash
sudo -E ./agent first-up
```

Nettoyage du runtime `strict-prod` (retour état "fresh"):

```bash
sudo ./agent strict-prod cleanup
# ou sans interaction:
sudo ./agent strict-prod cleanup --yes --no-backup
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

Equivalent one-shot command:

```bash
./agent first-up
```

Nettoyage du runtime `rootless-dev` (retour état "fresh"):

```bash
./agent rootless-dev cleanup
# ou sans interaction:
./agent rootless-dev cleanup --yes --no-backup
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

Au premier démarrage de `obs`, Grafana provisionne automatiquement le dashboard
`DGX Spark Agentic Activity Overview` (UID `dgx-spark-activity`) avec les datasources
`Prometheus` et `Loki`.

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
- `rag-retriever` (`7111`) et `rag-worker` (`7112`) ne sont pas publiés sur l'hôte.
- `opensearch` (`rag-lexical`) reste interne uniquement (pas de port host publié).
- `optional-openclaw` publie uniquement un ingress webhook local (`127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`), jamais en `0.0.0.0`.

Exemple Windows PowerShell (API Loki):

```powershell
$url = "http://127.0.0.1:13100/loki/api/v1/query_range?query=%7Bjob%3D%22egress-proxy%22%7D&limit=20"
(Invoke-RestMethod -Uri $url -Method Get).data.result
```

Notes Loki:
- `http://127.0.0.1:13100/` peut renvoyer `404 page not found` (normal).
- Utiliser Grafana (`http://127.0.0.1:13000`) pour l'UI, et Loki (`13100`) pour l'API.

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
agent [strict-prod|rootless-dev] <commande ...>
agent profile
agent first-up [--env-file <path>] [--no-env] [--dry-run]
agent up <core|agents|ui|obs|rag|optional>
agent down <core|agents|ui|obs|rag|optional>
agent stack <start|stop> <core|agents|ui|obs|rag|optional|all>
agent <claude|codex|opencode|vibestral> [project]
agent ls
agent ps
agent llm mode [local|hybrid|remote]
agent llm test-mode [on|off]
agent logs <service>
agent stop <tool>
agent stop service <service...>
agent stop container <container...>
agent start service <service...>
agent start container <container...>
agent backup <run|list|restore <snapshot_id> [--yes]>
agent forget <target> [--yes] [--no-backup]
agent cleanup [--yes] [--backup|--no-backup]
agent strict-prod cleanup [--yes] [--backup|--no-backup]
agent rootless-dev cleanup [--yes] [--backup|--no-backup]
agent net apply
agent ollama-link
agent ollama-preload [--generate-model <model>] [--embed-model <model>] [--budget-gb <int>] [--no-lock-ro]
agent ollama-models [status|rw|ro]
agent sudo-mode [status|on|off]
agent update
agent rollback all <release_id>
agent rollback host-net <backup_id>
agent rollback ollama-link <backup_id|latest>
agent onboard [--profile ... --root ... --compose-project ... --network ... --egress-network ... --ollama-models-dir ... --default-model ... --grafana-admin-user ... --grafana-admin-password ... --openwebui-allow-model-pull <true|false> --limits-default-cpus ... --limits-default-mem ... --limits-core-cpus ... --limits-core-mem ... --limits-agents-cpus ... --limits-agents-mem ... --limits-ui-cpus ... --limits-ui-mem ... --limits-obs-cpus ... --limits-obs-mem ... --limits-rag-cpus ... --limits-rag-mem ... --limits-optional-cpus ... --limits-optional-mem ... --output ... --non-interactive]
agent vm create [--name ... --cpus ... --memory ... --disk ... --image ... --workspace-path ... --reuse-existing --mount-repo|--no-mount-repo --require-gpu --skip-bootstrap --dry-run]
agent vm test [--name ... --workspace-path ... --test-selectors ... --require-gpu|--allow-no-gpu --skip-d5-tests --dry-run]
agent vm cleanup [--name ... --yes --dry-run]
agent test <A|B|C|D|E|F|G|H|I|J|K|L|V|all> [--skip-d5-tests]
agent doctor [--fix-net]
```

Exemples:

```bash
./agent up core
./agent up agents,ui
./agent first-up
./agent codex my-project
./agent logs ollama
./agent stop codex
./agent backup run
./agent backup list
./agent sudo-mode on
./agent update
./agent rollback all <release_id>
./agent test all --skip-d5-tests
./agent vm test --name agentic-strict-prod --allow-no-gpu --skip-d5-tests
```

Notes:
- `agent stop` gère les tools `claude|codex|opencode|vibestral`.
- `agent <tool> [project]` attache une session tmux persistante (shell déjà existant dans le conteneur): `Ctrl-b d` détache sans arrêter la session, et l'attache envoie un `Ctrl-c` puis `cd /workspace/<project>` (peut interrompre une commande en cours dans ce pane).
- `agent sudo-mode on` active `sudo` dans les conteneurs agents (en relachant uniquement `no-new-privileges` pour ces services); `agent sudo-mode off` revient au mode durci.
- `agent rollback all` exige un `release_id`.
- Utiliser `--skip-d5-tests` (ou `AGENTIC_SKIP_D5_TESTS=1`) pour ignorer uniquement `D5_gate_external_providers.sh` avec un warning si l'accès API externe n'est pas disponible.
- `agent cleanup` supprime aussi les images Docker locales de la stack et purge l'état sans suivre les symlinks.

## Ollama: preload et lien de modèles

En `rootless-dev`, le lien symbolique local des modèles est géré via:

```bash
./agent ollama-link
```

Préchargement avec préservation du mode de mount courant (`rw`/`ro`):

```bash
./agent ollama-preload
./agent ollama-models status
./agent ollama-models ro
./agent ollama-models rw
```

Pour changer le modèle local par défaut de la stack (et du preload):

```bash
export AGENTIC_DEFAULT_MODEL=llama3.2:1b
```

Rollback du lien:

```bash
./agent rollback ollama-link <backup_id|latest>
```

Test e2e du modèle par défaut (Ollama, gate, agents, OpenWebUI, OpenHands):

```bash
bash tests/L5_default_model_e2e.sh
bash tests/L6_codex_model_catalog.sh
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
- `./agent llm test-mode off` : valeur par défaut (production), dry-run gate désactivé.
- `./agent llm test-mode on` : activation explicite pour campagnes de test.

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
- Nettoyer la VM dédiée après campagne: `./agent vm cleanup --name agentic-strict-prod`

## Documentation détaillée

- Introduction (philosophie de la stack et modèle d'exploitation):
  - `docs/runbooks/introduction.md`
- Strategie d'implementation et priorites de refactoring:
  - `docs/runbooks/implementation-strategy-refactoring.md`
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
- Guide debutant de configuration (variables, valeurs, stockage, secrets):
  - `docs/runbooks/configuration-expliquee-debutants.md`
- Beginner configuration reference (variables, values, storage, secrets):
  - `docs/runbooks/configuration-explained-beginners.en.md`
- Images de developpement (build local, overrides, stamps, update/rollback):
  - `docs/runbooks/images-developpement.md`
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
