# Runbook: Images de developpement

Ce document explique comment la stack gere les images Docker construites localement pendant le developpement, et comment garder un comportement predictable (build, update, rollback).

## 1) Perimetre

Dans ce depot, une "image de developpement" est une image:
- construite localement depuis un Dockerfile du repo,
- taggee en local (souvent `agentic/...:local`),
- utilisee par `./agent up ...` et/ou `./agent update`.

Ce runbook couvre les images locales suivantes:

| Image locale | Dockerfile/source | Utilisee par | Build declenche par |
|---|---|---|---|
| `agentic/agent-cli-base:local` | `deployments/images/agent-cli-base/Dockerfile` | `agentic-claude`, `agentic-codex`, `agentic-opencode`, `agentic-vibestral`, `optional-pi-mono` | `./agent up agents`, `./agent update`, `./agent up optional` (si `pi-mono`) |
| `agentic/comfyui:local` | `deployments/images/comfyui/Dockerfile` | `comfyui` | `./agent up ui` (via Compose) |
| `agentic/ollama-gate:local` | `deployments/gate/Dockerfile` | `ollama-gate` | `./agent up core`, `./agent update` |
| `agentic/gate-mcp:local` | `deployments/gate_mcp/Dockerfile` | `gate-mcp` | `./agent up core`, `./agent update` |
| `agentic/optional-modules:local` | `deployments/optional/Dockerfile` | `optional-openclaw`, `optional-mcp-catalog` | `./agent up optional` (si modules actives) |

## 2) Logique de build automatique

### `./agent up core`

`agent` tente de (re)build:
- `ollama-gate`,
- `gate-mcp`.

Le build est intelligent (fingerprint + stamp) et ne rebuild pas si les inputs n'ont pas change.

Variable de contournement:
- `AGENTIC_SKIP_CORE_IMAGE_BUILD=1`

### `./agent up agents`

`agent` tente de (re)build l'image de base agents:
- `AGENTIC_AGENT_BASE_IMAGE` (defaut: `agentic/agent-cli-base:local`)
- depuis `AGENTIC_AGENT_BASE_DOCKERFILE` et `AGENTIC_AGENT_BASE_BUILD_CONTEXT`.

Apres build, un contrat minimum est verifie:
- user image non-root,
- `ENTRYPOINT` defini,
- `bash`, `tmux`, `git`, `curl` presents.

Le Dockerfile agents fournit aussi une matrice de CLIs:
- `codex`, `claude`, `opencode`, `vibe`, `openhands`, `openclaw`.

Mode d'installation des CLIs:
- `AGENT_CLI_INSTALL_MODE=best-effort` (defaut): build resilient, wrappers explicites en fallback.
- `AGENT_CLI_INSTALL_MODE=required`: build en echec si un install CLI ne peut pas etre resolu.

Trace d'installation dans l'image:
- `/etc/agentic/cli-install-status.tsv`
- `/etc/agentic/<cli>-real-path`

Variable de contournement:
- `AGENTIC_SKIP_AGENT_IMAGE_BUILD=1`

### `./agent up optional`

Si des modules optionnels sont actives, `agent` peut build:
- `agentic/optional-modules:local` (openclaw/mcp),
- `agentic/agent-cli-base:local` (pi-mono).

Variable de contournement:
- `AGENTIC_SKIP_OPTIONAL_IMAGE_BUILD=1`

### `./agent up ui`

`comfyui` declare un `build:` dans `compose/compose.ui.yml` avec:
- image cible `agentic/comfyui:local`,
- arg `COMFYUI_REF` (defaut `master`).

Important:
- contrairement a `core/agents/optional`, il n'y a pas de mecanisme de stamp specifique ComfyUI.
- si vous changez le Dockerfile et voulez forcer un rebuild, rebuild explicite recommande (voir section 6).

### `./agent update`

`agent update` fait, dans cet ordre:
1. build local `core` (si necessaire),
2. build local `agents` (si necessaire),
3. `docker compose ... pull --ignore-pull-failures`,
4. `docker compose ... up -d --remove-orphans`,
5. snapshot release (digests + compose effectif + etat).

## 3) Stamps de build (anti-rebuild inutile)

Les empreintes sont stockees dans:
- `${AGENTIC_ROOT}/deployments/image-build-stamps/`

Fichiers usuels:
- `ollama-gate-local.sha256`
- `gate-mcp-local.sha256`
- `agent-cli-base.sha256`
- `optional-modules-local.sha256`
- `agent-cli-base-local.sha256` (cas `optional-pi-mono`)

Usage:
- si l'empreinte correspond aux inputs actuels et que l'image existe, le build est saute,
- sinon `agent` rebuild et met a jour le stamp.

## 4) Override de l'image agents (cas custom)

Pour utiliser votre propre image/toolchain agents sans forker `compose.agents.yml`:

```bash
export AGENTIC_AGENT_BASE_IMAGE=agentic/agent-cli-base:custom
export AGENTIC_AGENT_BASE_BUILD_CONTEXT=/opt/agent-images/custom-base
export AGENTIC_AGENT_BASE_DOCKERFILE=/opt/agent-images/custom-base/Dockerfile
./agent up agents
```

Verification rapide:

```bash
./agent profile | rg 'agent_base_'
```

Ces valeurs sont persistees dans:
- `${AGENTIC_ROOT}/deployments/runtime.env`

## 5) Tracabilite release et rollback

Chaque `./agent update` cree une release sous:
- `${AGENTIC_ROOT}/deployments/releases/<timestamp>/`

Artefacts cles:
- `images.json` (image configuree + image resolue + repo digest si disponible),
- `compose.effective.yml`,
- `compose.files`,
- `runtime.env` (sanitise),
- `release.meta`.

Rollback deterministe:

```bash
./agent rollback all <release_id>
```

Note sur les images locales:
- un `repo_digest` peut etre vide pour des tags purement locaux,
- la trace reste exploitable via `configured_image` et `resolved_image`.

## 6) Forcer un rebuild propre

### Core / Agents / Optional

Option simple:
- modifier les inputs (Dockerfile, requirements, scripts) puis relancer `./agent up <stack>` ou `./agent update`.

Option explicite:

```bash
rm -f "${AGENTIC_ROOT}/deployments/image-build-stamps/agent-cli-base.sha256"
docker image rm agentic/agent-cli-base:local
./agent up agents
```

### ComfyUI

Rebuild explicite recommande:

```bash
docker image rm agentic/comfyui:local
./agent up ui
```

## 7) Validation rapide apres changement d'image

Checks minimum:

```bash
./agent doctor
./agent ls
docker image inspect agentic/agent-cli-base:local --format '{{.Config.User}}'
docker image inspect agentic/agent-cli-base:local --format '{{json .Config.Entrypoint}}'
```

Tests utilises par le repo:
- `tests/E1_image_build.sh`
- `tests/E1b_agent_base_image_override.sh`

## 8) Garde-fous a respecter

- pas de `docker.sock` dans les conteneurs applicatifs,
- services exposes en loopback host uniquement (`127.0.0.1`),
- secrets hors git (`${AGENTIC_ROOT}/secrets/runtime`, mode 600/640),
- Dockerfiles custom agents conformes au contrat minimal (non-root + entrypoint + outils de base).

## 9) References

- `compose/compose.core.yml`
- `compose/compose.agents.yml`
- `compose/compose.ui.yml`
- `compose/compose.optional.yml`
- `scripts/agent.sh`
- `deployments/releases/snapshot.sh`
- `docs/decisions/ADR-0026-stepE1b-agent-base-image-override.md`
- `docs/decisions/ADR-0032-stepE1-agent-base-cuda-dev-toolchain.md`
- `docs/decisions/ADR-0035-stepE1c-agent-cli-matrix.md`
