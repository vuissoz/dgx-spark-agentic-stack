#!/usr/bin/env python3
"""src/agentic/implementations/docker_runtime_adapter.py — Concrete AgentRuntimeAdapter (§7.1, §3.2).

Bridges the abstract AgentRuntimeAdapter contract to actual docker compose + tmux
session management, replicating the patterns used in scripts/agent.sh but with:
- structured data models instead of shell variables
- asyncio-friendly lifecycle (provision, observe, teardown)
- resource limit enforcement via docker compose constraints
- idempotent session recreation from manifest state

Conforms to:
- AgentRuntimeAdapter (plan/provision/observe/teardown/apply_limits)
- Scheduler integration for resource admission tracking
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess
from dataclasses import dataclass, field
from typing import Any, Optional


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.join(SCRIPT_DIR, "..", "..")


@dataclass(frozen=True)
class SandboxSnapshot:
    """Persistent state for cold session recreation."""
    harness: str
    image_tag: str
    workspace_path: str
    session_name: str
    project: Optional[str] = None
    limits_cpu: float = 1.0
    limits_memory_mb: int = 1024
    model_context_window: int = 50909
    agent_default_model: str = "qwen3.8:27b"


@dataclass(frozen=True)
class SandboxState:
    """Live state of an active agent session."""
    sandbox_id: str           # container name (e.g., agentic-codex-1)
    harness: str
    running: bool
    healthy: bool             # tmux session exists inside container
    workspace: str
    model: str = ""
    context_tokens_used: int = 0
    restart_count: int = 0


@dataclass(frozen=True)
class ProvisionResult:
    success: bool
    sandbox_id: Optional[str] = None
    snapshot: Optional[SandboxSnapshot] = None
    error: str = ""


@dataclass(frozen=True)
class TeardownResult:
    success: bool
    freed_resources: dict[str, Any] = field(default_factory=dict)
    error: str = ""


class DockerRuntimeAdapter:
    """Concrete implementation of AgentRuntimeAdapter using docker compose and tmux.

    This adapter manages the lifecycle of agent sessions (Claude, Codex, OpenCode, etc.)
    inside pre-built agent-cli-base containers. Each harness gets a persistent tmux session
    that survives SSH disconnects, enabling cold recovery from workspace state.

    Usage:
        adapter = DockerRuntimeAdapter(project="agentic-dev")
        result = await adapter.provision_sandbox({
            "harness": "codex",
            "workspace": "/srv/agentic/codex/workspaces/workspace-main",
            "cpu": 2.0,
            "memory_mb": 2048,
        })
    """

    def __init__(self, project: str = "agentic-dev", env: Optional[dict[str, str]] = None):
        self.project = project
        self.env = env or {**os.environ}

    # ── AgentRuntimeAdapter contract methods ─────────────────────────────
    async def provision_sandbox(self, context: dict[str, Any]) -> dict[str, Any]:
        """Provision a new sandbox for user + agent + project.

        In practice, the container already exists (created by compose up).
        This method creates/verifies the tmux session inside the running container
        and records runtime state.
        """
        harness = context.get("harness", "codex")
        workspace = context.get("workspace", f"/srv/agentic/{harness}/workspaces/workspace-default")
        cpu = float(context.get("cpu", 1.0))
        memory_mb = int(context.get("memory_mb", 1024))

        # Map harness to container name (follows compose service naming: agentic-{harness})
        service_name = f"agentic-{harness}"
        sandbox_id = self._find_container(service_name)

        if not sandbox_id:
            return {
                "success": False,
                "error": f"Container not found for service '{service_name}'. Run 'docker compose up' first.",
            }

        # Create tmux session inside container (idempotent — only if missing)
        tmux_session = f"{harness}"
        tmux_exists = self._check_tmux_session(sandbox_id, tmux_session)

        if not tmux_exists:
            # Navigate to workspace and initialize session
            success = self._init_tmux_session(sandbox_id, tmux_session, workspace)
            if not success:
                return {"success": False, "error": f"Failed to create tmux session '{tmux_session}' in {sandbox_id}"}

        # Build snapshot for cold recovery
        model = context.get("model", "qwen3.8:27b")
        context_window = int(context.get("context_window", 50909))

        snapshot = SandboxSnapshot(
            harness=harness,
            image_tag=self._get_container_image(sandbox_id),
            workspace_path=workspace,
            session_name=tmux_session,
            project=context.get("project"),
            limits_cpu=cpu,
            limits_memory_mb=memory_mb,
            model_context_window=context_window,
            agent_default_model=model,
        )

        state = SandboxState(
            sandbox_id=sandbox_id,
            harness=harness,
            running=True,
            healthy=tmux_exists or True,  # newly created = healthy
            workspace=workspace,
            model=model,
            context_tokens_used=0,
        )

        return {
            "success": True,
            "sandbox_id": sandbox_id,
            "state": self._snapshot_state(state),
            "snapshot": self._snapshot_snapshot(snapshot),
            "mode": "tmux",  # compatible with existing agent.sh session_mode
        }

    async def observe_sandbox(self, sandbox_id: str) -> dict[str, Any]:
        """Observe the current state of a running sandbox."""
        if not self._container_running(sandbox_id):
            return {"success": False, "error": f"Container {sandbox_id} is not running", "running": False}

        # Extract harness from container name (agentic-{harness}-1)
        harness = self._extract_harness(sandbox_id)
        tmux_session = harness if harness else "unknown"

        healthy = self._check_tmux_session(sandbox_id, tmux_session)
        workspace = self._get_container_workspace(sandbox_id, harness or "")

        # Estimate context usage from container logs (stub — real impl reads ollama-gate metrics)
        context_tokens = self._estimate_context_usage(sandbox_id, harness or "codex")

        return {
            "success": True,
            "sandbox_id": sandbox_id,
            "harness": harness or "unknown",
            "running": True,
            "healthy": healthy,
            "workspace": workspace,
            "tmux_session": tmux_session,
            "context_tokens_estimated": context_tokens,
        }

    async def teardown_sandbox(self, sandbox_id: str) -> bool:
        """Tear down (stop/kill) a sandbox. Returns True if successful."""
        # Stop the tmux session inside the container first
        harness = self._extract_harness(sandbox_id)
        tmux_session = harness or ""

        self._kill_tmux_session(sandbox_id, tmux_session) if tmux_session else None

        # Then stop the docker container
        try:
            result = subprocess.run(
                ["docker", "stop", sandbox_id],
                capture_output=True, text=True, timeout=30, env=self.env,
            )
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    async def apply_limits(self, sandbox_id: str, cpu: float, memory_mb: int, gpu: bool = False) -> bool:
        """Apply resource limits to a running sandbox.

        In docker compose, limits are set at container creation time via
        the CPU/MEM/GPU environment variables. To change limits on an existing
        container requires recreating it (which tears down the session).

        This method logs the intent and returns True with a warning that
        recreation is required for live changes.
        """
        # In production, this would:
        # 1. Snapshot current state
        # 2. docker stop && docker rm
        # 3. Recreate compose container with new limits
        # 4. Restore tmux session and workspace state

        return {
            "success": False,
            "warning": f"Live limit change requires sandbox recreation. New: cpu={cpu} mem={memory_mb}MB gpu={gpu}",
        }

    # ── Internal helpers ─────────────────────────────────────────────────
    def _find_container(self, service_name: str) -> Optional[str]:
        """Find running container for a compose service."""
        try:
            result = subprocess.run(
                ["docker", "ps", "--filter", f"label=com.docker.compose.service={service_name}",
                 "--format", "{{.Names}}"],
                capture_output=True, text=True, env=self.env,
            )
            names = [n for n in result.stdout.strip().split("\n") if n.strip()]
            return names[0] if names else None
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return None

    def _container_running(self, container_id: str) -> bool:
        """Check if a container is currently running."""
        try:
            result = subprocess.run(
                ["docker", "inspect", "-f", "{{.State.Running}}", container_id],
                capture_output=True, text=True, env=self.env,
            )
            return result.returncode == 0 and "true" in result.stdout.lower()
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    def _check_tmux_session(self, container_id: str, session_name: str) -> bool:
        """Check if a tmux session exists inside the container."""
        try:
            result = subprocess.run(
                ["docker", "exec", container_id, "tmux", "has-session", "-t", session_name],
                capture_output=True, text=True, env=self.env,
            )
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    def _init_tmux_session(self, container_id: str, session_name: str, workspace: str) -> bool:
        """Create a new tmux session inside the container."""
        try:
            # Create detached session and cd to workspace
            proc1 = subprocess.run(
                ["docker", "exec", container_id, "tmux", "new-session", "-d", "-s", session_name,
                 "-c", workspace],
                capture_output=True, text=True, env=self.env,
            )
            if proc1.returncode != 0:
                return False

            # Send C-c and cd to ensure clean state
            subprocess.run(
                ["docker", "exec", container_id, "sh", "-c", f"tmux send-keys -t {session_name} C-c"],
                capture_output=True, text=True, env=self.env,
                check=False,
            )
            return True
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False

    def _kill_tmux_session(self, container_id: str, session_name: str) -> None:
        """Kill tmux session inside container."""
        try:
            subprocess.run(
                ["docker", "exec", container_id, "tmux", "kill-session", "-t", session_name],
                capture_output=True, text=True, env=self.env, check=False,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    def _extract_harness(self, container_id: str) -> Optional[str]:
        """Extract harness name from container id (e.g., agentic-codex-1 -> codex)."""
        # Pattern: agentic-{harness}-1 or just {harness}
        m = re.match(r"agentic-(.+?)-?\d*$", container_id)
        if m:
            return m.group(1)
        return None

    def _get_container_image(self, container_id: str) -> str:
        """Get the image tag for a running container."""
        try:
            result = subprocess.run(
                ["docker", "inspect", "-f", "{{.Config.Image}}", container_id],
                capture_output=True, text=True, env=self.env,
            )
            return result.stdout.strip() if result.returncode == 0 else ""
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return ""

    def _get_container_workspace(self, container_id: str, harness: str) -> str:
        """Get workspace path from container volumes/env (best-effort)."""
        # In compose, workspaces are mounted; we extract the host path
        try:
            result = subprocess.run(
                ["docker", "inspect", "-f",
                 "{{range .Mounts}}{{if eq .Destination \"/workspace\"}}{{.Source}}{{end}}{{end}}",
                 container_id],
                capture_output=True, text=True, env=self.env,
            )
            host_path = result.stdout.strip()
            if host_path:
                return host_path  # This is the host workspace path
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

        return f"/srv/agentic/{harness or 'agent'}/workspaces/workspace-default"

    def _estimate_context_usage(self, container_id: str, harness: str) -> int:
        """Estimate context tokens used by inspecting gate metrics (stub)."""
        # In production, this would query ollama-gate /metrics for the session's token count
        return 0

    # ── Serialization helpers ────────────────────────────────────────────
    def _snapshot_state(self, state: SandboxState) -> dict[str, Any]:
        import json as _json
        return {
            "sandbox_id": state.sandbox_id,
            "harness": state.harness,
            "running": state.running,
            "healthy": state.healthy,
            "workspace": state.workspace,
            "model": state.model,
            "context_tokens_used": state.context_tokens_used,
        }

    def _snapshot_snapshot(self, snap: SandboxSnapshot) -> dict[str, Any]:
        import json as _json
        return {
            "harness": snap.harness,
            "image_tag": snap.image_tag,
            "workspace_path": snap.workspace_path,
            "session_name": snap.session_name,
            "project": snap.project,
            "limits_cpu": snap.limits_cpu,
            "limits_memory_mb": snap.limits_memory_mb,
            "model_context_window": snap.model_context_window,
            "agent_default_model": snap.agent_default_model,
        }


# ── CLI entry point for standalone usage ───────────────────────────────
def main() -> int:
    """Quick inspection of current agent sandboxes."""
    import argparse

    parser = argparse.ArgumentParser(description="Docker Runtime Adapter — inspect/manage agent sessions")
    parser.add_argument("--project", default="agentic-dev", help="Compose project name")
    parser.add_argument("--action", choices=["list", "observe", "help"], default="list")
    args = parser.parse_args()

    adapter = DockerRuntimeAdapter(project=args.project)

    if args.action == "list":
        # List all agentic-* containers
        try:
            result = subprocess.run(
                ["docker", "ps", "--filter", "label=com.docker.compose.service=agentic-",
                 "--format", "{{.Names}}\t{{.Image}}\t{{.Status}}"],
                capture_output=True, text=True, env=os.environ,
            )
            for line in result.stdout.strip().split("\n"):
                if line.strip():
                    print(line)
        except FileNotFoundError:
            print("ERROR: docker not found")
            return 1

    elif args.action == "observe":
        container = adapter._find_container(f"agentic-codex") or adapter._find_container(f"agentic-claude")
        if container:
            result = asyncio.run(adapter.observe_sandbox(container))
            print(json.dumps(result, indent=2))
        else:
            print("No running agentic-* containers found")

    return 0


if __name__ == "__main__":
    sys.exit(main())
