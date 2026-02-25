# Runbook: Configuration de la Stack (Version Debutant)

Ce runbook est la reference de configuration de la stack.
Il explique:
- quelles valeurs sont configurables,
- quelles valeurs sont autorisees,
- ou chaque valeur est stockee,
- comment gerer les secrets et cles API proprement.

## 1. Comment la configuration est resolue

La configuration vient de 5 sources:

1. Variables d'environnement du shell
- Exemple: `export AGENTIC_PROFILE=strict-prod`

2. Fichier genere par l'onboarding
- Fichier par defaut: `.runtime/env.generated.sh`
- Genere par: `./agent onboard ...`
- Charge avec: `source .runtime/env.generated.sh`

3. Fichier runtime gere par `agent`
- Fichier: `${AGENTIC_ROOT}/deployments/runtime.env`
- Mis a jour automatiquement par `agent up`, `agent llm mode`, `agent llm test-mode`, `agent ollama-models`, `agent ollama-preload`, etc.

4. Fichiers de configuration sous `${AGENTIC_ROOT}`
- Exemple: `${AGENTIC_ROOT}/proxy/allowlist.txt`
- Exemple: `${AGENTIC_ROOT}/gate/config/model_routes.yml`

5. Fichiers secrets sous `${AGENTIC_ROOT}/secrets/runtime`
- Exemple: `${AGENTIC_ROOT}/secrets/runtime/openai.api_key`

Point important:
- Pour de nombreuses variables coeur, `runtime.env` devient la valeur effective quand vous lancez `./agent`.
- Si une cle est deja presente dans `runtime.env`, modifier seulement le shell peut ne pas suffire.

## 2. Choix recommandes si vous debutez

- Profil:
  - `strict-prod` pour usage operationnel/validation CDC.
  - `rootless-dev` pour developpement local sans root.

- Mode LLM:
  - `hybrid` dans la plupart des cas.
  - `local` pour bloquer explicitement les providers externes.
  - `remote` si vous utilisez des providers externes et voulez liberer GPU/RAM locale.

- Modules optionnels:
  - desactives par defaut.
  - activer seulement apres `./agent doctor` vert.

- Montage des modeles Ollama:
  - `rw` pour preload/mise a jour,
  - `ro` pour smoke tests deterministes.

## 3. Catalogue des variables

## 3.1 Identite runtime

| Variable | Valeurs possibles | Defaut (`strict-prod`) | Defaut (`rootless-dev`) | Stockage |
|---|---|---|---|---|
| `AGENTIC_PROFILE` | `strict-prod` ou `rootless-dev` | `strict-prod` | `rootless-dev` si exporte | shell, `runtime.env` |
| `AGENTIC_ROOT` | chemin absolu | `/srv/agentic` | `${HOME}/.local/share/agentic` | shell, `runtime.env` |
| `AGENTIC_COMPOSE_PROJECT` | nom Compose (`[a-zA-Z0-9][a-zA-Z0-9_.-]*`) | `agentic` | `agentic-dev` | shell, `runtime.env` |
| `AGENTIC_NETWORK` | nom reseau Docker | `agentic` | `agentic-dev` | shell, `runtime.env` |
| `AGENTIC_LLM_NETWORK` | nom reseau Docker | `agentic-llm` | `agentic-dev-llm` | shell, `runtime.env` |
| `AGENTIC_EGRESS_NETWORK` | nom reseau Docker | `agentic-egress` | `agentic-dev-egress` | shell, `runtime.env` |

## 3.2 Selection des stacks et profiles Compose

| Variable | Valeurs possibles | Defaut | Stockage |
|---|---|---|---|
| `AGENTIC_STACK_ALL_TARGETS` | liste CSV de `core,agents,ui,obs,rag,optional` (sous-ensemble possible) | `core,agents,ui,obs,rag,optional` | shell |
| `AGENTIC_OPTIONAL_MODULES` | liste CSV de `openclaw,mcp,pi-mono,goose,portainer` | vide | shell |
| `COMPOSE_PROFILES` | liste CSV. Supporte ici: `trt`, `rag-lexical` | vide | shell |

Notes:
- `trt` active `trtllm` dans `core`.
- `rag-lexical` active `opensearch` dans `rag`.

## 3.3 Routage LLM, quotas, limites MCP

| Variable | Valeurs possibles | Defaut | Stockage |
|---|---|---|---|
| `AGENTIC_LLM_MODE` | `local`, `hybrid`, `remote` | `hybrid` | `runtime.env`, `${AGENTIC_ROOT}/gate/state/llm_mode.json` |
| `GATE_ENABLE_TEST_MODE` | `0` (off) ou `1` (on) | `0` | `runtime.env` |
| `AGENTIC_OPENAI_DAILY_TOKENS` | entier `>= 0` (`0` = non limite/off) | `0` | `runtime.env` |
| `AGENTIC_OPENAI_MONTHLY_TOKENS` | entier `>= 0` | `0` | `runtime.env` |
| `AGENTIC_OPENAI_DAILY_REQUESTS` | entier `>= 0` | `0` | `runtime.env` |
| `AGENTIC_OPENAI_MONTHLY_REQUESTS` | entier `>= 0` | `0` | `runtime.env` |
| `AGENTIC_OPENROUTER_DAILY_TOKENS` | entier `>= 0` | `0` | `runtime.env` |
| `AGENTIC_OPENROUTER_MONTHLY_TOKENS` | entier `>= 0` | `0` | `runtime.env` |
| `AGENTIC_OPENROUTER_DAILY_REQUESTS` | entier `>= 0` | `0` | `runtime.env` |
| `AGENTIC_OPENROUTER_MONTHLY_REQUESTS` | entier `>= 0` | `0` | `runtime.env` |
| `GATE_MCP_RATE_LIMIT_RPS` | flottant `> 0` | `5` | `runtime.env` |
| `GATE_MCP_RATE_LIMIT_BURST` | entier `>= 1` | `10` | `runtime.env` |
| `GATE_MCP_HTTP_TIMEOUT_SEC` | flottant `> 0` | `5` | `runtime.env` |
| `GATE_MCP_ALLOWED_MODEL_REGEX` | regex valide (vide = regex par defaut) | vide | `runtime.env` |

## 3.4 Store modeles et IDs modeles

| Variable | Valeurs possibles | Defaut | Stockage |
|---|---|---|---|
| `OLLAMA_MODELS_DIR` | chemin absolu | `${AGENTIC_ROOT}/ollama/models` | shell, `runtime.env` |
| `AGENTIC_OLLAMA_MODELS_LINK` | chemin absolu (symlink rootless) | `${REPO}/.runtime/ollama-models` | shell, `runtime.env` |
| `AGENTIC_OLLAMA_MODELS_TARGET_DIR` | chemin absolu (target rootless) | `${REPO}/.runtime/ollama-models-data` | shell, `runtime.env` |
| `OLLAMA_CONTAINER_MODELS_PATH` | chemin interne conteneur | `/root/.ollama/models` | `/tmp/ollama/models` en `rootless-dev` |
| `OLLAMA_MODELS_MOUNT_MODE` | `rw` ou `ro` | `rw` | `runtime.env` |
| `OLLAMA_PRELOAD_GENERATE_MODEL` | identifiant de modele | `qwen3:0.6b` | `runtime.env` |
| `OLLAMA_PRELOAD_EMBED_MODEL` | identifiant de modele | `qwen3-embedding:0.6b` | `runtime.env` |
| `OLLAMA_MODEL_STORE_BUDGET_GB` | entier positif | `12` | `runtime.env` |
| `RAG_EMBED_MODEL` | identifiant de modele | `qwen3-embedding:0.6b` | `runtime.env` |
| `TRTLLM_MODELS` | selecteur modele/backend | `qwen3-nvfp4-demo` | shell |
| `COMFYUI_REF` | ref git pour build image ComfyUI | `master` | shell |
| `COMFYUI_MANAGER_REPO` | repo git extension manager ComfyUI (vide = desactive) | `https://github.com/ltdrdata/ComfyUI-Manager.git` | shell |
| `COMFYUI_MANAGER_REF` | ref git extension manager ComfyUI | `main` | shell |

## 3.5 Variables de ports publies host

Tous les ports restent en loopback (`127.0.0.1`).

| Variable | Service | Defaut |
|---|---|---|
| `OPENWEBUI_HOST_PORT` | OpenWebUI | `8080` |
| `OPENHANDS_HOST_PORT` | OpenHands | `3000` |
| `COMFYUI_HOST_PORT` | bridge loopback ComfyUI | `8188` |
| `GRAFANA_HOST_PORT` | Grafana | `13000` |
| `PROMETHEUS_HOST_PORT` | Prometheus | `19090` |
| `LOKI_HOST_PORT` | Loki | `13100` |
| `PORTAINER_HOST_PORT` | Portainer optionnel | `9001` |
| `OPENCLAW_WEBHOOK_HOST_PORT` | webhook OpenClaw optionnel | `18111` |

## 3.6 Limites ressources

Defauts par stack (persistes en `runtime.env`):
- `AGENTIC_LIMIT_DEFAULT_CPUS`, `AGENTIC_LIMIT_DEFAULT_MEM`
- `AGENTIC_LIMIT_CORE_CPUS`, `AGENTIC_LIMIT_CORE_MEM`
- `AGENTIC_LIMIT_AGENTS_CPUS`, `AGENTIC_LIMIT_AGENTS_MEM`
- `AGENTIC_LIMIT_UI_CPUS`, `AGENTIC_LIMIT_UI_MEM`
- `AGENTIC_LIMIT_OBS_CPUS`, `AGENTIC_LIMIT_OBS_MEM`
- `AGENTIC_LIMIT_RAG_CPUS`, `AGENTIC_LIMIT_RAG_MEM`
- `AGENTIC_LIMIT_OPTIONAL_CPUS`, `AGENTIC_LIMIT_OPTIONAL_MEM`

Overrides service par service:
- `AGENTIC_LIMIT_<SERVICE_NAME>_CPUS`
- `AGENTIC_LIMIT_<SERVICE_NAME>_MEM`

Exemples:
- `AGENTIC_LIMIT_OLLAMA_MEM=6g`
- `AGENTIC_LIMIT_OPENWEBUI_CPUS=0.60`
- `AGENTIC_LIMIT_OPTIONAL_OPENCLAW_MEM=768m`

Formats:
- CPU: decimal positif (`0.5`, `1`, `2.5`)
- Memoire: format Docker (`512m`, `1g`, `2G`)

## 3.7 UID/GID conteneurs et montages observabilite

UID/GID conteneurs:
- `AGENT_RUNTIME_UID`, `AGENT_RUNTIME_GID`
- `OLLAMA_CONTAINER_USER`, `QDRANT_CONTAINER_USER`, `GATE_CONTAINER_USER`, `TRTLLM_CONTAINER_USER`
- `PROMETHEUS_CONTAINER_USER`, `GRAFANA_CONTAINER_USER`, `LOKI_CONTAINER_USER`, `PROMTAIL_CONTAINER_USER`

Overrides chemins de montage host pour observabilite:
- `PROMTAIL_DOCKER_CONTAINERS_HOST_PATH` (defaut `/var/lib/docker/containers`)
- `PROMTAIL_HOST_LOG_PATH` (defaut `/var/log`)
- `NODE_EXPORTER_HOST_ROOT_PATH` (defaut `/`)
- `CADVISOR_HOST_ROOT_PATH` (defaut `/`)
- `CADVISOR_DOCKER_LIB_HOST_PATH` (defaut `/var/lib/docker`)
- `CADVISOR_SYS_HOST_PATH` (defaut `/sys`)
- `CADVISOR_DEV_DISK_HOST_PATH` (defaut `/dev/disk`)

## 3.8 Toggles operationnels et controles avances

Toggles frequents (`0` ou `1`):
- `AGENTIC_SKIP_DOCKER_USER_APPLY`
- `AGENTIC_SKIP_DOCKER_USER_CHECK`
- `AGENTIC_SKIP_DOCTOR_PROXY_CHECK`
- `AGENTIC_SKIP_OPTIONAL_GATING`
- `AGENTIC_SKIP_CORE_IMAGE_BUILD`
- `AGENTIC_SKIP_AGENT_IMAGE_BUILD`
- `AGENTIC_SKIP_OPTIONAL_IMAGE_BUILD`
- `AGENTIC_DISABLE_AUTO_SNAPSHOT`

Autres variables utiles:
- `AGENT_LOG_TAIL` (defaut `200`)
- `AGENT_PROJECT_NAME`
- `AGENT_NO_ATTACH=1`
- `AGENTIC_DOCTOR_CRITICAL_PORTS`

Retention backup:
- `AGENTIC_BACKUP_KEEP_HOURLY` (defaut `24`)
- `AGENTIC_BACKUP_KEEP_DAILY` (defaut `14`)
- `AGENTIC_BACKUP_KEEP_WEEKLY` (defaut `8`)

Options avancees firewall/egress:
- `AGENTIC_DOCKER_USER_CHAIN`
- `AGENTIC_DOCKER_USER_SOURCE_NETWORKS` (defaut: `${AGENTIC_NETWORK},${AGENTIC_EGRESS_NETWORK}`)
- `AGENTIC_DOCKER_USER_LOG_PREFIX`
- `AGENTIC_PROXY_SERVICE`, `AGENTIC_PROXY_PORT`
- `AGENTIC_UNBOUND_SERVICE`, `AGENTIC_UNBOUND_PORT`
- `AGENTIC_GATE_SERVICE`, `AGENTIC_GATE_PORT`
- `AGENTIC_OLLAMA_SERVICE`, `AGENTIC_OLLAMA_PORT`
- `AGENTIC_SERVICE_IP_RESOLVE_ATTEMPTS`, `AGENTIC_SERVICE_IP_RESOLVE_SLEEP_SECONDS`
- `AGENTIC_SKIP_HOST_NET_BACKUP`
- `AGENTIC_ALLOW_NON_ROOT_NET_ADMIN`

## 3.9 Override image agents et credentials admin

| Variable | Valeurs possibles | Defaut | Stockage |
|---|---|---|---|
| `AGENTIC_AGENT_BASE_IMAGE` | reference image Docker | `agentic/agent-cli-base:local` | shell, `runtime.env` |
| `AGENTIC_AGENT_BASE_BUILD_CONTEXT` | chemin absolu ou relatif au repo | racine du repo | shell, `runtime.env` |
| `AGENTIC_AGENT_BASE_DOCKERFILE` | chemin absolu ou relatif au repo | `deployments/images/agent-cli-base/Dockerfile` | shell, `runtime.env` |
| `AGENTIC_AGENT_CLI_INSTALL_MODE` | `best-effort` ou `required` | `best-effort` | shell, `runtime.env` |
| `AGENTIC_AGENT_NO_NEW_PRIVILEGES` | `true` ou `false` | `true` | shell, `runtime.env` |
| `AGENTIC_CODEX_CLI_NPM_SPEC` | spec npm | `@openai/codex@latest` | shell, `runtime.env` |
| `AGENTIC_CLAUDE_CODE_NPM_SPEC` | spec npm | `@anthropic-ai/claude-code@latest` | shell, `runtime.env` |
| `AGENTIC_OPENCODE_NPM_SPEC` | spec npm | `opencode-ai@latest` | shell, `runtime.env` |
| `AGENTIC_OPENHANDS_INSTALL_SCRIPT` | URL script install | `https://install.openhands.dev/install.sh` | shell, `runtime.env` |
| `AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT` | URL script install | `https://openclaw.ai/install-cli.sh` | shell, `runtime.env` |
| `AGENTIC_OPENCLAW_INSTALL_VERSION` | version OpenClaw CLI | `latest` | shell, `runtime.env` |
| `AGENTIC_VIBE_INSTALL_SCRIPT` | URL script install | `https://mistral.ai/vibe/install.sh` | shell, `runtime.env` |
| `GRAFANA_ADMIN_USER` | chaine non vide | `admin` | shell/secret manager |
| `GRAFANA_ADMIN_PASSWORD` | chaine non vide | `change-me` | shell/secret manager |

Notes:
- `GRAFANA_ADMIN_*` est lu directement par Compose pour `grafana`; ce n'est pas gere comme secret fichier par les scripts d'init.
- Preferer une injection locale (secret manager ou export shell ponctuel) plutot qu'un fichier versionne.
- `AGENTIC_AGENT_NO_NEW_PRIVILEGES=false` active le mode `sudo` intra-conteneur pour `agentic-{claude,codex,opencode,vibestral}` (`./agent sudo-mode on`), avec compromis hardening explicite.

## 3.10 Variables runtime RAG

| Variable | Valeurs possibles | Defaut | Stockage |
|---|---|---|---|
| `RAG_COLLECTION` | nom d'index/collection (lettres, chiffres, `_`, `-`) | `agentic_docs` | shell |
| `RAG_LEXICAL_INDEX` | nom d'index | `agentic_docs` | shell |
| `RAG_EMBED_MODEL` | identifiant modele | `qwen3-embedding:0.6b` | shell, `runtime.env` |
| `RAG_GATE_DRY_RUN` | `0` ou `1` | `1` | shell |
| `RAG_LEXICAL_BACKEND` | `disabled` ou `opensearch` | `disabled` | shell |
| `RAG_FUSION_METHOD` | actuellement `rrf` | `rrf` | shell |
| `RAG_RRF_K` | entier `>= 1` | `60` | shell |
| `RAG_WORKER_BOOTSTRAP_INDEX` | `0` ou `1` | `1` | shell |

Notes:
- `RAG_LEXICAL_BACKEND=opensearch` est pertinent seulement si `COMPOSE_PROFILES=rag-lexical` est actif.
- `RAG_DENSE_BACKEND` existe dans le code service, mais le baseline Compose le fixe a `qdrant`.

## 3.11 Variables onboarding/scripts specifiques

| Variable | Portee | Defaut | Stockage |
|---|---|---|---|
| `AGENTIC_ONBOARD_OUTPUT` | chemin du fichier genere par `agent onboard` | `${REPO}/.runtime/env.generated.sh` | shell |
| `AGENTIC_SKIP_OLLAMA_LINK_BACKUP` | skip backup du lien modeles (`0`/`1`) | `0` | shell |
| `AGENTIC_SKIP_GROUP_CREATE` | skip creation groupe host au bootstrap (`0`/`1`) | `0` | shell |

Ce sont des variables avancees d'operation, rarement necessaires en usage quotidien.

## 4. Fichiers de config importants

Fichiers de base crees par les scripts d'init:

- `${AGENTIC_ROOT}/gate/config/model_routes.yml`
- `${AGENTIC_ROOT}/proxy/config/squid.conf`
- `${AGENTIC_ROOT}/proxy/allowlist.txt`
- `${AGENTIC_ROOT}/dns/unbound.conf`
- `${AGENTIC_ROOT}/openwebui/config/openwebui.env`
- `${AGENTIC_ROOT}/openhands/config/openhands.env`
- `${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt`
- `${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt`
- `${AGENTIC_ROOT}/optional/mcp/config/tool_allowlist.txt`
- `${AGENTIC_ROOT}/deployments/optional/<module>.request`

Cles `openwebui.env` (fichier sensible en `600`):
- `WEBUI_ADMIN_EMAIL`
- `WEBUI_ADMIN_PASSWORD`
- `OPENAI_API_KEY`
- `WEBUI_SECRET_KEY`

Cles `openhands.env` (fichier sensible en `600`):
- `LLM_MODEL`
- `LLM_API_KEY` (en local via `ollama-gate`: n'importe quelle valeur non vide, ex `local-ollama`)

## 5. Secrets et cles API

## 5.1 Emplacement

Tous les secrets fichier sont sous:
- `${AGENTIC_ROOT}/secrets/runtime/`

Secrets baseline + optionnels:
- `${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token` (cree automatiquement si absent)
- `${AGENTIC_ROOT}/secrets/runtime/openai.api_key` (optionnel, routage OpenAI)
- `${AGENTIC_ROOT}/secrets/runtime/openrouter.api_key` (optionnel, routage OpenRouter)
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.token` (requis si `openclaw` actif)
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret` (requis si `openclaw` actif)
- `${AGENTIC_ROOT}/secrets/runtime/mcp.token` (requis si module `mcp` actif)

## 5.2 Permissions requises

- Dossiers secrets: `0700`
- Fichiers secrets: `0600` (ou `0640` quand explicitement tolere)

Creation securisee:

```bash
umask 077
mkdir -p "${AGENTIC_ROOT}/secrets/runtime"
printf '%s\n' '<token-ou-cle>' > "${AGENTIC_ROOT}/secrets/runtime/openai.api_key"
chmod 600 "${AGENTIC_ROOT}/secrets/runtime/openai.api_key"
```

## 5.3 Rotation

1. Remplacer le contenu du secret.
2. Garder mode `600`.
3. Recreer la stack concernee.
- Exemple: `./agent up core`
- Exemple optionnel: `AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional`
4. Lancer `./agent doctor`.

## 5.4 A ne pas faire

- Ne jamais commit de secrets dans git.
- Ne pas mettre de secrets dans des `.env` versionnes dans le repo.
- Ne pas copier de secrets dans des logs/issues.

## 6. Ou les valeurs sont persistees (tracabilite)

Etat runtime:
- `${AGENTIC_ROOT}/deployments/runtime.env`
- `${AGENTIC_ROOT}/gate/state/llm_mode.json`
- `${AGENTIC_ROOT}/gate/state/quotas_state.json`

Tracabilite release (`agent update` / snapshot):
- `${AGENTIC_ROOT}/deployments/releases/<release_id>/images.json`
- `${AGENTIC_ROOT}/deployments/releases/<release_id>/compose.effective.yml`
- `${AGENTIC_ROOT}/deployments/releases/<release_id>/runtime.env` (sanitize)
- `${AGENTIC_ROOT}/deployments/current` (symlink release active)

Backups:
- `${AGENTIC_ROOT}/deployments/backups/snapshots/...`
- metadata backup avec config runtime sanitisee (filtrage des cles type secret/token/password/api_key).

## 7. Commandes de verification

A lancer apres toute modif de configuration:

```bash
./agent profile
./agent doctor
./agent ps
```

Checks utiles:

```bash
# Valeurs runtime persistantes
sed -n '1,200p' "${AGENTIC_ROOT}/deployments/runtime.env"

# Mode LLM effectif
cat "${AGENTIC_ROOT}/gate/state/llm_mode.json"

# Permissions des secrets
find "${AGENTIC_ROOT}/secrets/runtime" -maxdepth 1 -type f -printf '%m %p\n'
```
