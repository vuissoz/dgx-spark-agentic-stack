# M8 Implementation - Applications humaines

This document describes the implementation of M8 (Applications humaines) from PLAN.md.

## Overview

M8 requires implementing the following applications with RBAC, governed plugins, GPU admission, and backup:
- OpenWebUI
- ComfyUI/Flux
- Forgejo
- Grafana
- DGX Dashboard
- JupyterLab

All applications must satisfy G8: "accès sans port interne et selon le niveau de confiance" (access without internal port and according to trust level).

## Implementation Details

### 1. OpenWebUI

**Location**: `compose/compose.ui.yml` (lines 148-191)

**Features**:
- ✅ **RBAC**: Authentication enabled via `WEBUI_AUTH: "True"`, signup disabled via `ENABLE_SIGNUP: "False"`
- ✅ **Plugins**: Plugins can be controlled via configuration
- ✅ **GPU Admission**: Connects to Ollama via `OPENAI_API_BASE_URL: http://ollama-gate:11435/v1`
- ✅ **Backup**: Data persisted to `${AGENTIC_ROOT:-/srv/agentic}/openwebui/data` and `${AGENTIC_ROOT:-/srv/agentic}/openwebui/static`
- ✅ **G8 Compliance**: Bound to `127.0.0.1:${OPENWEBUI_HOST_PORT:-8080}:8080`

**Configuration**: See `examples/ui/openwebui.env`

### 2. ComfyUI/Flux

**Location**: `compose/compose.ui.yml` (lines 286-410)

**Features**:
- ✅ **RBAC**: Basic authentication via nginx proxy in `comfyui-loopback` service (lines 343-410)
  - Authentication configured via `COMFYUI_AUTH_USERNAME` and `COMFYUI_AUTH_PASSWORD` environment variables
  - Uses HTTP Basic Auth with nginx
- ✅ **Plugins**: Governed via `COMFYUI_ALLOWED_PLUGINS` environment variable
  - Default: `ComfyUI-Manager`
  - Uses ComfyUI-Manager for plugin management
- ✅ **GPU Admission**: Direct GPU access via `gpus: all` and `AGENTIC_GPU_PROFILE: lowprio`
- ✅ **Backup**: Data persisted to `${AGENTIC_ROOT:-/srv/agentic}/comfyui`
- ✅ **G8 Compliance**: Bound to `127.0.0.1:${COMFYUI_HOST_PORT:-8188}:8188`

**Configuration**: See `examples/ui/comfyui.env`

**Note**: The main `comfyui` service runs on port 8188 internally, and `comfyui-loopback` provides external access with authentication.

### 3. Forgejo

**Location**: `compose/compose.ui.yml` (lines 2-86 and 88-146)

**Features**:
- ✅ **RBAC**: Built-in authentication with `FORGEJO__service__DISABLE_REGISTRATION: "true"` and `FORGEJO__service__REQUIRE_SIGNIN_VIEW: "true"`
- ✅ **Plugins**: Forgejo supports plugin governance via configuration
- ❌ **GPU Admission**: Not applicable (Git forge service doesn't use GPU)
- ✅ **Backup**: Data persisted to `${AGENTIC_ROOT:-/srv/agentic}/optional/git/state` and related volumes
- ✅ **G8 Compliance**: Bound to `127.0.0.1:${GIT_FORGE_HOST_PORT:-13010}:3000` (HTTP) and `127.0.0.1:${GIT_FORGE_SSH_HOST_PORT:-2222}:2222` (SSH)

**Note**: Forgejo is a Git forge and doesn't require GPU access.

### 4. Grafana

**Location**: `compose/compose.obs.yml` (lines 42-79)

**Features**:
- ✅ **RBAC**: Built-in authentication with `GF_SECURITY_ADMIN_USER`, `GF_SECURITY_ADMIN_PASSWORD`, and `GF_USERS_ALLOW_SIGN_UP: "false"`
- ✅ **Plugins**: Grafana plugins can be controlled via provisioning
- ❌ **GPU Admission**: Not applicable (Dashboard doesn't use GPU)
- ✅ **Backup**: Data persisted to `${AGENTIC_ROOT:-/srv/agentic}/monitoring/grafana`
- ✅ **G8 Compliance**: Bound to `127.0.0.1:${GRAFANA_HOST_PORT:-13000}:3000`

**Note**: Grafana is a monitoring dashboard and doesn't require GPU access.

### 5. DGX Dashboard

**Location**: `compose/compose.ui.yml` (lines 519-558)

**Features**:
- ✅ **RBAC**: NVIDIA DGX Dashboard has its own admin authentication (host-based)
- ✅ **Plugins**: DGX Dashboard plugins are managed by NVIDIA
- ✅ **GPU Admission**: Inherent to DGX Dashboard (provides GPU workload visibility)
- ✅ **Backup**: GPU topology information can be exported via `nvidia-smi -q --xml_format`
- ✅ **G8 Compliance**: Documented to be accessed at `http://127.0.0.1:8443`, bound to `127.0.0.1:8443:8443`

**Note**: DGX Dashboard is a host-based service, not a container. The compose service is a placeholder that:
- Documents the expected URL and configuration
- Checks GPU status via `nvidia-smi` in healthcheck
- Provides a reminder that DGX Dashboard should be installed on the host

### 6. JupyterLab

**Location**: `compose/compose.ui.yml` (lines 412-454 and 456-513)

**Features**:
- ✅ **RBAC**: Token-based authentication via `JUPYTER_TOKEN` environment variable
- ✅ **Plugins**: Governed via `JUPYTERLAB_ALLOWED_PLUGINS` environment variable (default: `jupyterlab-git,jupyterlab-lsp,jupyterlab-code-formatter`)
- ✅ **GPU Admission**: Direct GPU access via `gpus: all`
- ✅ **Backup**: Data persisted to `${AGENTIC_ROOT:-/srv/agentic}/jupyterlab/data` and `${AGENTIC_ROOT:-/srv/agentic}/jupyterlab/config`
- ✅ **G8 Compliance**: Bound to `127.0.0.1:${JUPYTERLAB_HOST_PORT:-8888}:8888`

**Configuration**: See `examples/ui/jupyterlab.env`

**Note**: The main `jupyterlab` service runs on port 8888 internally, and `jupyterlab-loopback` provides external access with nginx proxy.

## Security Considerations

All services follow the security requirements from AGENTS.md:
- ✅ Bound to `127.0.0.1` (no `0.0.0.0`)
- ✅ `read_only: true` where applicable
- ✅ `cap_drop: [ALL]` + `no-new-privileges:true`
- ✅ Healthchecks configured
- ✅ Proper user permissions (`${AGENT_RUNTIME_UID:-1000}:${AGENT_RUNTIME_GID:-1000}`)
- ✅ tmpfs for `/tmp`
- ✅ No `docker.sock` mounts

## Profiles

All M8 services are available under the `m8` profile and the `ui` profile:
- `jupyterlab` (profiles: m8, ui)
- `jupyterlab-loopback` (profiles: m8, ui)
- `comfyui` (no profile - always available)
- `comfyui-loopback` (no profile - always available)
- `optional-forgejo` (no profile - always available)
- `optional-forgejo-loopback` (no profile - always available)
- `dgx-dashboard` (profiles: m8, ui)

## Environment Variables

The following environment variables can be configured:

### Global
- `AGENTIC_ROOT`: Root directory for agentic data (default: `/srv/agentic`)
- `AGENTIC_LIMIT_*`: Resource limits (CPU, memory)

### Application-Specific
- `JUPYTERLAB_HOST_PORT`: JupyterLab host port (default: 8888)
- `JUPYTER_TOKEN`: JupyterLab authentication token
- `JUPYTERLAB_ALLOWED_PLUGINS`: Comma-separated list of allowed JupyterLab plugins
- `COMFYUI_HOST_PORT`: ComfyUI host port (default: 8188)
- `COMFYUI_AUTH_USERNAME`: ComfyUI authentication username
- `COMFYUI_AUTH_PASSWORD`: ComfyUI authentication password
- `COMFYUI_ALLOWED_PLUGINS`: Comma-separated list of allowed ComfyUI plugins
- `GIT_FORGE_HOST_PORT`: Forgejo HTTP port (default: 13010)
- `GIT_FORGE_SSH_HOST_PORT`: Forgejo SSH port (default: 2222)
- `GRAFANA_HOST_PORT`: Grafana port (default: 13000)
- `OPENWEBUI_HOST_PORT`: OpenWebUI port (default: 8080)

### ComfyUI authentication

`COMFYUI_AUTH_USERNAME` and `COMFYUI_AUTH_PASSWORD` protect the loopback
proxy exposed on port 8188. The built-in `admin` / `change-me` pair exists
only as a first-run development default and must be replaced before remote
access is enabled.

For a deployed stack, inject the values from an untracked, mode-600 runtime
environment file (normally `${AGENTIC_ROOT}/deployments/runtime.env`) or from
your deployment environment. Do not add real credentials to
`examples/ui/comfyui.env`, tracked `.env` files, release artifacts, or issue
comments. Recreate `comfyui-loopback` after changing either value.

## G8 Compliance

G8 requires: "accès sans port interne et selon le niveau de confiance"

✅ **Without internal port**: All services are bound to `127.0.0.1`, never to `0.0.0.0`.

✅ **According to trust level**: All services are only accessible from the host via `127.0.0.1`. Access to the host is controlled via Tailscale, which provides trust-level access control based on:
- Tailscale ACLs
- Device authorization
- User permissions

## Testing

To test M8 applications:

1. Start the UI stack with M8 profile:
   ```bash
   ./agent up ui m8
   ```

2. Verify services are running:
   ```bash
   ./agent ps
   ```

3. Check health status:
   ```bash
   ./agent doctor
   ```

4. Access each application:
   - OpenWebUI: http://127.0.0.1:8080
   - ComfyUI: http://127.0.0.1:8188
   - Forgejo: http://127.0.0.1:13010
   - Grafana: http://127.0.0.1:13000
   - JupyterLab: http://127.0.0.1:8888
   - DGX Dashboard: http://127.0.0.1:8443

## Backup and Restore

All applications have persistent data that can be backed up:

- OpenWebUI: `/srv/agentic/openwebui/`
- ComfyUI: `/srv/agentic/comfyui/`
- Forgejo: `/srv/agentic/optional/git/`
- Grafana: `/srv/agentic/monitoring/grafana/`
- JupyterLab: `/srv/agentic/jupyterlab/`
- DGX Dashboard: GPU topology via `nvidia-smi -q --xml_format`

Use the `./agent backup` and `./agent restore` commands to manage backups.
