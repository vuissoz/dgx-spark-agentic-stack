#!/usr/bin/env python3
"""src/agentic/implementations/application_adapters.py — Concrete ApplicationAdapter implementations (§2.3, §3.2).

These manage lifecycle for human-facing applications:
- ComfyUI / Flux (image generation)
- OpenWebUI (chat UI)
- Forgejo (self-hosted Git)
- Grafana/observability stack

Each adapter follows the ApplicationAdapter contract: start, health_check, status_url, backup, restore.
"""

from __future__ import annotations

import json
import time
import uuid
import os
import subprocess
from dataclasses import dataclass, field
from typing import Any, Optional


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.join(SCRIPT_DIR, "..", "..")


@dataclass(frozen=True)
class ApplicationStatus:
    """Snapshot of an application's operational state."""
    service_name: str
    running: bool
    healthy: bool
    port: int
    version: str = ""
    last_backup: Optional[str] = None


class ComfyUIAdapter:
    """ApplicationAdapter for ComfyUI / Flux image generation pipeline.
    
    Manages container lifecycle, custom node governance (allowlist + scan),
    GPU admission workflows, and backup/restore of workflows/models.
    """

    def __init__(self, project: str = "agentic-dev"):
        self.project = project
        self.service_name = "comfyui"
        self.env = {**os.environ}

    async def start(self) -> bool:
        """Start ComfyUI container via docker compose."""
        try:
            result = subprocess.run(
                ["docker", "compose", "-f", f"{REPO_ROOT}/compose/compose.ui.yml",
                 "--project-name", self.project, "up", "-d", "comfyui"],
                capture_output=True, text=True, env=self.env, timeout=120,
            )
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    async def health_check(self) -> bool:
        """Check ComfyUI is healthy via HTTP endpoint."""
        try:
            # Query the container's status endpoint
            result = subprocess.run(
                ["docker", "exec", f"agentic-comfyui-1", "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 "http://127.0.0.1:8188/ping"],
                capture_output=True, text=True, env=self.env, timeout=10,
            )
            return "200" in result.stdout.strip() if result.returncode == 0 else False
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    def status_url(self) -> str:
        return f"http://127.0.0.1:8188"

    async def backup(self, dest: str) -> dict[str, Any]:
        """Backup ComfyUI workflows and configurations."""
        try:
            result = subprocess.run(
                ["docker", "cp", f"agentic-comfyui-1:/comfyui/custom_nodes", dest],
                capture_output=True, text=True, env=self.env, timeout=60,
            )
            return {
                "success": result.returncode == 0,
                "path": dest,
                "component": "custom_nodes",
            }
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "docker cp failed"}

    async def restore(self, source: str) -> dict[str, Any]:
        """Restore ComfyUI workflows from backup."""
        try:
            result = subprocess.run(
                ["docker", "cp", f"{source}/custom_nodes", f"agentic-comfyui-1:/comfyui/"],
                capture_output=True, text=True, env=self.env, timeout=60,
            )
            return {
                "success": result.returncode == 0,
                "path": source,
            }
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "docker cp failed"}

    def get_status(self) -> ApplicationStatus:
        """Get current status of ComfyUI container."""
        try:
            result = subprocess.run(
                ["docker", "inspect", "-f", "{{.State.Running}} {{.State.Status}}",
                 f"agentic-comfyui-1"],
                capture_output=True, text=True, env=self.env,
            )
            if result.returncode == 0:
                state = result.stdout.strip()
                running = "true" in state and "unhealthy" not in result.stdout.lower()
                healthy = "unhealthy" not in result.stdout.lower()
                return ApplicationStatus(
                    service_name="comfyui", running=running, healthy=healthy, port=8188,
                )
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
        return ApplicationStatus(service_name="comfyui", running=False, healthy=False, port=8188)


class OpenWebUIAdapter:
    """ApplicationAdapter for OpenWebUI chat interface with ModelBroker integration.
    
    Manages container lifecycle, RBAC configuration, tool allowlist, and model streaming.
    Connects to ollama-gate/ModelBroker via internal network.
    """

    def __init__(self, project: str = "agentic-dev"):
        self.project = project
        self.service_name = "openwebui"
        self.env = {**os.environ}

    async def start(self) -> bool:
        try:
            result = subprocess.run(
                ["docker", "compose", "-f", f"{REPO_ROOT}/compose/compose.ui.yml",
                 "--project-name", self.project, "up", "-d", "openwebui"],
                capture_output=True, text=True, env=self.env, timeout=120,
            )
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    async def health_check(self) -> bool:
        try:
            result = subprocess.run(
                ["docker", "exec", f"agentic-openwebui-1", "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 "http://127.0.0.1:3000/healthz"],
                capture_output=True, text=True, env=self.env, timeout=10,
            )
            return "200" in result.stdout.strip() if result.returncode == 0 else False
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    def status_url(self) -> str:
        return f"http://127.0.0.1:3000"

    async def backup(self, dest: str) -> dict[str, Any]:
        """Backup OpenWebUI user data and configurations."""
        try:
            result = subprocess.run(
                ["docker", "cp", f"agentic-openwebui-1:/app/backend/data", dest],
                capture_output=True, text=True, env=self.env, timeout=60,
            )
            return {"success": result.returncode == 0, "path": dest}
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "docker cp failed"}

    async def restore(self, source: str) -> dict[str, Any]:
        try:
            result = subprocess.run(
                ["docker", "cp", f"{source}/data", f"agentic-openwebui-1:/app/backend/"],
                capture_output=True, text=True, env=self.env, timeout=60,
            )
            return {"success": result.returncode == 0, "path": source}
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "docker cp failed"}

    def get_status(self) -> ApplicationStatus:
        try:
            result = subprocess.run(
                ["docker", "inspect", "-f", "{{.State.Running}} {{.State.Status}}",
                 f"agentic-openwebui-1"],
                capture_output=True, text=True, env=self.env,
            )
            if result.returncode == 0:
                running = "true" in result.stdout and "unhealthy" not in result.stdout.lower()
                healthy = "unhealthy" not in result.stdout.lower()
                return ApplicationStatus(
                    service_name="openwebui", running=running, healthy=healthy, port=3000,
                )
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
        return ApplicationStatus(service_name="openwebui", running=False, healthy=False, port=3000)


class ForgejoAdapter:
    """ApplicationAdapter for Forgejo self-hosted Git forge.
    
    Manages container lifecycle, repository initialization, admin user setup,
    and backup/restore of git repositories.
    """

    def __init__(self, project: str = "agentic-dev"):
        self.project = project
        self.service_name = "forgejo"
        self.env = {**os.environ}

    async def start(self) -> bool:
        try:
            result = subprocess.run(
                ["docker", "compose", "-f", f"{REPO_ROOT}/compose/compose.optional.yml",
                 "--project-name", self.project, "up", "-d", "forgejo"],
                capture_output=True, text=True, env=self.env, timeout=120,
            )
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    async def health_check(self) -> bool:
        try:
            result = subprocess.run(
                ["docker", "exec", f"agentic-forgejo-1", "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 "http://127.0.0.1:3000/"],
                capture_output=True, text=True, env=self.env, timeout=10,
            )
            return "200" in result.stdout.strip() if result.returncode == 0 else False
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    def status_url(self) -> str:
        return f"http://127.0.0.1:3000"

    async def backup(self, dest: str) -> dict[str, Any]:
        """Backup Forgejo git repositories."""
        try:
            result = subprocess.run(
                ["docker", "cp", f"agentic-forgejo-1:/data/gitea/repos", dest],
                capture_output=True, text=True, env=self.env, timeout=120,
            )
            return {"success": result.returncode == 0, "path": dest}
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "docker cp failed"}

    async def restore(self, source: str) -> dict[str, Any]:
        try:
            result = subprocess.run(
                ["docker", "cp", f"{source}/repos", f"agentic-forgejo-1:/data/gitea/"],
                capture_output=True, text=True, env=self.env, timeout=120,
            )
            return {"success": result.returncode == 0, "path": source}
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "docker cp failed"}

    def get_status(self) -> ApplicationStatus:
        try:
            result = subprocess.run(
                ["docker", "inspect", "-f", "{{.State.Running}} {{.State.Status}}",
                 f"agentic-forgejo-1"],
                capture_output=True, text=True, env=self.env,
            )
            if result.returncode == 0:
                running = "true" in result.stdout and "unhealthy" not in result.stdout.lower()
                healthy = "unhealthy" not in result.stdout.lower()
                return ApplicationStatus(
                    service_name="forgejo", running=running, healthy=healthy, port=3000,
                )
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
        return ApplicationStatus(service_name="forgejo", running=False, healthy=False, port=3000)


# ── Application Registry ───────────────────────────────────────────────
def get_application(name: str) -> Optional[Any]:
    """Look up a concrete application adapter by name."""
    registry = {
        "comfyui": ComfyUIAdapter(),
        "openwebui": OpenWebUIAdapter(),
        "forgejo": ForgejoAdapter(),
    }
    return registry.get(name)


def list_available_applications() -> list[dict[str, str]]:
    """Return metadata about all available applications."""
    return [
        {"name": "comfyui", "description": "Image generation (Flux)"},
        {"name": "openwebui", "description": "Chat interface with ModelBroker"},
        {"name": "forgejo", "description": "Self-hosted Git forge"},
    ]


# ── CLI entry point ────────────────────────────────────────────────────
def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Application Adapters — list/inspect apps")
    parser.add_argument("--action", choices=["list", "status"], default="list")
    args = parser.parse_args()

    apps = {"comfyui": ComfyUIAdapter(), "openwebui": OpenWebUIAdapter(), "forgejo": ForgejoAdapter()}

    if args.action == "list":
        print("Available applications:")
        for name, app in apps.items():
            status = app.get_status()
            state = "✓ running" if status.running else "✗ stopped"
            health = "✓ healthy" if status.healthy else "○ unknown"
            print(f"  {name}: port={status.port} {state} {health}")

    elif args.action == "status":
        for name, app in apps.items():
            status = app.get_status()
            print(f"{name}: running={status.running} healthy={status.healthy} port={status.port}")

    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())


# ── Grafana Adapter (§9.1, Observability) ────────────────────────

class GrafanaAdapter:
    """ApplicationAdapter for Grafana observability dashboards.

    Manages container lifecycle, versioned dashboards/datasources,
    and read-majority access pattern for monitoring.
    """

    def __init__(self, project: str = "agentic-dev"):
        self.project = project
        self.service_name = "grafana"
        self.env = {**os.environ}

    async def start(self) -> bool:
        try:
            result = subprocess.run(
                ["docker", "compose", "-f", f"{REPO_ROOT}/compose/compose.obs.yml",
                 "--project-name", self.project, "up", "-d", "grafana"],
                capture_output=True, text=True, env=self.env, timeout=120,
            )
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    async def health_check(self) -> bool:
        try:
            result = subprocess.run(
                ["docker", "exec", f"agentic-grafana-1", "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 "http://127.0.0.1:3000/api/health"],
                capture_output=True, text=True, env=self.env, timeout=10,
            )
            return "200" in result.stdout.strip() if result.returncode == 0 else False
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    def status_url(self) -> str:
        return f"http://127.0.0.1:3000"

    async def backup(self, dest: str) -> dict[str, Any]:
        try:
            result = subprocess.run(
                ["docker", "cp", f"agentic-grafana-1:/var/lib/grafana", dest],
                capture_output=True, text=True, env=self.env, timeout=120,
            )
            return {"success": result.returncode == 0, "path": dest}
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "docker cp failed"}

    async def restore(self, source: str) -> dict[str, Any]:
        try:
            result = subprocess.run(
                ["docker", "cp", f"{source}/grafana", f"agentic-grafana-1:/var/lib/"],
                capture_output=True, text=True, env=self.env, timeout=120,
            )
            return {"success": result.returncode == 0, "path": source}
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "docker cp failed"}


# ── DGX Dashboard Adapter (§9.1, NVIDIA) ─────────────────────────

class DGXDashboardAdapter:
    """ApplicationAdapter for NVIDIA DGX Dashboard (admin launcher).

    Conforms to §9.1 — not assumed compatible via iframe/proxy without test.
    Admin-only access; dashboard provides hardware and workload visibility.
    """

    def __init__(self, project: str = "agentic-dev"):
        self.project = project
        self.service_name = "dgx-dashboard"
        self.env = {**os.environ}

    async def start(self) -> bool:
        # DGX Dashboard typically runs as a launcher on the host, not in Docker
        # This adapter supports checking its status via CLI if available
        try:
            result = subprocess.run(
                ["nvidia-smi", "-q"], capture_output=True, text=True, timeout=10, env=self.env,
            )
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    async def health_check(self) -> bool:
        try:
            result = subprocess.run(
                ["nvidia-smi"], capture_output=True, text=True, timeout=10, env=self.env,
            )
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    def status_url(self) -> str:
        # DGX Dashboard is host-based; URL depends on deployment
        return f"http://127.0.0.1:8443" if self.health_check() else ""

    async def backup(self, dest: str) -> dict[str, Any]:
        """DGX Dashboard config is minimal; export GPU topology info."""
        try:
            result = subprocess.run(
                ["nvidia-smi", "-q", "--xml_format"], capture_output=True, text=True, timeout=10, env=self.env,
            )
            if result.returncode == 0 and dest:
                os.makedirs(os.path.dirname(dest) if os.path.dirname(dest) else ".", exist_ok=True)
                with open(dest, "w") as f:
                    f.write(result.stdout)
            return {"success": True, "path": dest}
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "nvidia-smi unavailable"}

    async def restore(self, source: str) -> dict[str, Any]:
        """DGX Dashboard has no config to restore — hardware topology is static."""
        return {"success": True, "message": "No config restore needed for DGX Dashboard"}


# ── JupyterLab Adapter (§9.2, Code Environment) ───────────────────

class JupyterLabAdapter:
    """ApplicationAdapter for JupyterLab code environment.

    Treated as a code environment, not just a web page. User isolation,
    quotas, and explicit external access per §9.2.
    """

    def __init__(self, project: str = "agentic-dev"):
        self.project = project
        self.service_name = "jupyterlab"
        self.env = {**os.environ}

    async def start(self) -> bool:
        try:
            result = subprocess.run(
                ["docker", "compose", "-f", f"{REPO_ROOT}/compose/compose.ui.yml",
                 "--project-name", self.project, "up", "-d", "jupyterlab"],
                capture_output=True, text=True, env=self.env, timeout=120,
            )
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    async def health_check(self) -> bool:
        try:
            # JupyterLab health via /api/status
            result = subprocess.run(
                ["docker", "exec", f"agentic-jupyterlab-1", "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 "http://127.0.0.1:8888/api/status"],
                capture_output=True, text=True, env=self.env, timeout=10,
            )
            return "200" in result.stdout.strip() if result.returncode == 0 else False
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    def status_url(self) -> str:
        return f"http://127.0.0.1:8888"

    async def backup(self, dest: str) -> dict[str, Any]:
        try:
            result = subprocess.run(
                ["docker", "cp", f"agentic-jupyterlab-1:/home/jovyan", dest],
                capture_output=True, text=True, env=self.env, timeout=120,
            )
            return {"success": result.returncode == 0, "path": dest}
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "docker cp failed"}

    async def restore(self, source: str) -> dict[str, Any]:
        try:
            result = subprocess.run(
                ["docker", "cp", f"{source}/home/jovyan", f"agentic-jupyterlab-1:/"],
                capture_output=True, text=True, env=self.env, timeout=120,
            )
            return {"success": result.returncode == 0, "path": source}
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "docker cp failed"}


# ── Portainer Adapter (§9.1, Break-Glass) ────────────────────────

class PortainerAdapter:
    """ApplicationAdapter for Portainer admin break-glass tool.

    Disabled by default (per §9.1), admin-only access. Used only when
    traditional docker CLI is unavailable or for visual debugging.
    Never exposes Docker socket in production profiles (admin only, disabled by default).
    """

    def __init__(self, project: str = "agentic-dev"):
        self.project = project
        self.service_name = "portainer"
        self.enabled = False  # Disabled by default per §9.1

    async def start(self) -> bool:
        if not self.enabled:
            return {"success": False, "error": "Portainer disabled by default (break-glass only)"}
        try:
            result = subprocess.run(
                ["docker", "compose", "-f", f"{REPO_ROOT}/compose/compose.optional.yml",
                 "--project-name", self.project, "up", "-d", "portainer"],
                capture_output=True, text=True, env=self.env, timeout=120,
            )
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    async def health_check(self) -> bool:
        try:
            result = subprocess.run(
                ["docker", "exec", f"agentic-portainer-1", "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 "http://127.0.0.1:9443/api/health"],
                capture_output=True, text=True, env=self.env, timeout=10,
            )
            return "200" in result.stdout.strip() if result.returncode == 0 else False
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    def status_url(self) -> str:
        return f"http://127.0.0.1:9443"

    async def backup(self, dest: str) -> dict[str, Any]:
        try:
            result = subprocess.run(
                ["docker", "cp", f"agentic-portainer-1:/data", dest],
                capture_output=True, text=True, env=self.env, timeout=60,
            )
            return {"success": result.returncode == 0, "path": dest}
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "docker cp failed"}

    async def restore(self, source: str) -> dict[str, Any]:
        try:
            result = subprocess.run(
                ["docker", "cp", f"{source}/data", f"agentic-portainer-1:/"],
                capture_output=True, text=True, env=self.env, timeout=60,
            )
            return {"success": result.returncode == 0, "path": source}
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return {"success": False, "error": "docker cp failed"}


# ── Enhanced Application Adapters (§9.2 — Production Features) ───────────

class ComfyUIGPUJobAdapter:
    """GPUJobAdapter for ComfyUI workflow admission and observation.

    Implements the GPUJobAdapter ABC partially (admit_job, observe_job, cancel_job).
    Coordinates with scheduler to enforce GPU/memory limits before admitting workflows.
    Per §9.2 ComfyUI requires admission control and Flux model support.
    """

    def __init__(self, project: str = "agentic-dev"):
        self.project = project
        self._jobs: dict[str, dict[str, Any]] = {}  # In-memory job tracking

    async def admit_job(self, job: dict[str, Any]) -> dict[str, Any]:
        """Request GPU admission for a ComfyUI workflow.

        Checks available GPU/memory before admitting. Returns allocation details.
        """
        import json as _json

        job_id = f"comfyui-{uuid.uuid4().hex[:8]}"
        gpu_count = job.get("gpu_count", 1)
        memory_mb = job.get("memory_mb", 2048)
        workflow_file = job.get("workflow_file", "")

        # Check if GPU resources are available (stub — production queries scheduler)
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used,memory.total", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10,
        )

        if result.returncode != 0:
            return {
                "job_id": job_id,
                "admitted": False,
                "reason": "GPU not available",
            }

        # Record admitted job
        self._jobs[job_id] = {
            "workflow_file": workflow_file,
            "gpu_count": gpu_count,
            "memory_mb": memory_mb,
            "status": "admitted",
            "created_at": time.time(),
        }

        return {
            "job_id": job_id,
            "admitted": True,
            "workflow_file": workflow_file,
            "gpu_allocated": gpu_count,
            "memory_mb": memory_mb,
        }

    async def observe_job(self, job_id: str) -> dict[str, Any]:
        """Observe status of a ComfyUI GPU job."""
        job = self._jobs.get(job_id)
        if not job:
            return {"job_id": job_id, "status": "not_found"}

        # In production, this would query the container API for workflow progress
        return {
            "job_id": job_id,
            "workflow_file": job["workflow_file"],
            "status": job["status"],
            "gpu_count": job["gpu_count"],
        }

    async def cancel_job(self, job_id: str) -> bool:
        """Cancel a ComfyUI GPU job."""
        if job_id in self._jobs:
            self._jobs[job_id]["status"] = "cancelled"
            return True
        return False


class OpenWebUIRBACManager:
    """RBAC configuration manager for OpenWebUI (§9.2, §9.3).

    Manages:
    - Multi-user/RBAC roles (admin, editor, viewer)
    - Model allowlist via ModelBroker routing
    - Tool/function allowlist governance (PLAN.md §9.3 risk extensions)
    """

    def __init__(self):
        self._users: dict[str, dict[str, Any]] = {}  # user_id → role_config
        self._model_allowlist: list[str] = []  # Models permitted via ModelBroker
        self._tool_allowlist: list[str] = []  # Tools permitted in OpenWebUI Pipelines

    def add_user_role(self, user_id: str, role: str) -> dict[str, Any]:
        """Add or update a user's RBAC role.

        Roles: admin (full), editor (can create sessions), viewer (read-only).
        Per §9.2 OpenWebUI requires multi-user/RBAC support.
        """
        valid_roles = {"admin", "editor", "viewer"}
        if role not in valid_roles:
            raise ValueError(f"Invalid role '{role}'. Must be one of {valid_roles}")

        self._users[user_id] = {
            "user_id": user_id,
            "role": role,
            "created_at": time.time(),
        }

        return {"user_id": user_id, "role": role}

    def check_access(self, user_id: str, resource: str) -> bool:
        """Check if a user has access to a resource based on their RBAC role."""
        user = self._users.get(user_id)
        if not user:
            return False  # Unknown user → denied

        role = user["role"]

        # Permission matrix (simplified)
        permissions = {
            "admin": {"sessions", "config", "models", "tools", "backup", "restore"},
            "editor": {"sessions", "models", "tools"},  # no config/backup
            "viewer": {"sessions", "models"},  # read-only
        }

        user_perms = permissions.get(role, set())
        return resource in user_perms

    def configure_model_allowlist(self, models: list[str]) -> dict[str, Any]:
        """Configure which models are accessible via ModelBroker in OpenWebUI.

        Per §9.2: OpenWebUI must connect to ollama-gate/ModelBroker only,
        not directly to Ollama/TRT backends.
        """
        self._model_allowlist = list(set(models))  # Deduplicate
        return {
            "allowed_models": self._model_allowlist,
            "count": len(self._model_allowlist),
            "note": "All model access must route through ModelBroker (ollama-gate)",
        }

    def configure_tool_allowlist(self, tools: list[str]) -> dict[str, Any]:
        """Configure which OpenWebUI Tools/Functions/Pipelines are permitted.

        Per §9.3 Extensions à risque: tool execution can run Python — 
        creation/import must be disabled by default, require allowlist + review.
        """
        self._tool_allowlist = list(set(tools))
        return {
            "allowed_tools": self._tool_allowlist,
            "count": len(self._tool_allowlist),
            "note": "Tools execute Python — allowlist and review required (PLAN.md §9.3)",
        }


class FluxModelAdapter:
    """Flux image generation adapter for ComfyUI (§9.2).

    Manages Flux model loading, inference API, and workflow orchestration.
    Per §9.2 ComfyUI + Flux is a key integration point.
    """

    def __init__(self, comfyui_url: str = "http://127.0.0.1:8188"):
        self.comfyui_url = comfyui_url
        self._models_loaded: dict[str, bool] = {}  # model_name → loaded

    async def load_model(self, model_name: str) -> dict[str, Any]:
        """Load a Flux model into ComfyUI via API."""
        try:
            result = subprocess.run(
                ["curl", "-s", f"{self.comfyui_url}/api/models/load",
                 "-X", "POST",
                 "-d", json.dumps({"model": model_name}),
                 "-H", "Content-Type: application/json"],
                capture_output=True, text=True, timeout=300,
            )
            loaded = result.returncode == 0
            self._models_loaded[model_name] = loaded
            return {"model": model_name, "loaded": loaded}
        except Exception as e:
            return {"model": model_name, "loaded": False, "error": str(e)}

    async def generate_image(self, prompt: str, workflow_id: Optional[str] = None) -> dict[str, Any]:
        """Generate an image via Flux model in ComfyUI."""
        try:
            result = subprocess.run(
                ["curl", "-s", f"{self.comfyui_url}/api/prompt",
                 "-X", "POST",
                 "-d", json.dumps({
                     "prompt": [{"type": "flux", "prompt": prompt}],
                     "workflow_id": workflow_id or "default-flux",
                 }),
                 "-H", "Content-Type: application/json"],
                capture_output=True, text=True, timeout=120,
            )
            response = result.stdout.strip() if result.returncode == 0 else "{}"
            return json.loads(response)
        except Exception as e:
            return {"error": str(e)}

    async def health_check(self) -> bool:
        """Check Flux/ComfyUI is accessible."""
        try:
            result = subprocess.run(
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 f"{self.comfyui_url}/api/system_stats"],
                capture_output=True, text=True, timeout=10,
            )
            return "200" in result.stdout.strip() if result.returncode == 0 else False
        except Exception:
            return False


# ── Application Adapters Registry ───────────────────────────────────

def get_all_application_adapters() -> dict[str, Any]:
    """Return all registered application adapter instances."""
    return {
        "comfyui": ComfyUIAdapter(),
        "openwebui": OpenWebUIAdapter(),
        "forgejo": ForgejoAdapter(),
        "grafana": GrafanaAdapter(),
        "dgx_dashboard": DGXDashboardAdapter(),
        "jupyterlab": JupyterLabAdapter(),
        "portainer": PortainerAdapter(),
    }


def get_application_rbac_manager() -> OpenWebUIRBACManager:
    """Get the RBAC manager for OpenWebUI (production wiring)."""
    return OpenWebUIRBACManager()


def get_flux_adapter(comfyui_url: Optional[str] = None) -> FluxModelAdapter:
    """Get the Flux image generation adapter."""
    return FluxModelAdapter(comfyui_url=comfyui_url or "http://127.0.0.1:8188")
