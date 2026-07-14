#!/usr/bin/env python3
"""scripts/control_plane.py — v2 control-plane CLI commands.

Called by agent.sh for: model-route, session, auth, scheduler operations.
Implements PLAN.md §6 (ModelBroker), §5 (Identity/Sessions), §10.2 (ExternalAccess), §11 (Scheduler).

Usage:
    python3 control_plane.py model-route [--json]
    python3 control_plane.py session start <harness> [project]
    python3 control_plane.py session list [harness]
    python3 control_plane.py session end <session_id>
    python3 control_plane.py auth rotate <service> [scope]
    python3 control_plane.py scheduler status
    python3 control_plane.py scheduler stats
"""

import argparse
import asyncio
import json
import os
import shutil
import sys
from pathlib import Path


def ensure_src_path():
    """Ensure src/ is on Python path."""
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src = os.path.join(repo_root, "src")
    if src not in sys.path:
        sys.path.insert(0, src)


# ── Model Route (PLAN §6) ────────────────────────────────────────

def cmd_model_route(args):
    """List available models via ModelBroker (§6)."""
    ensure_src_path()
    try:
        from agentic.implementations.model_broker import ModelBroker
        broker = ModelBroker()
        models = broker.list_models()
        if args.json:
            print(json.dumps({"models": models}, indent=2))
        else:
            print("Available models (via ModelBroker):")
            for m in models:
                name = m.get("name", "?")
                backend = m.get("backend", "unknown")
                tags = ", ".join(m.get("tags", []))
                print(f"  {name} (backend={backend}, {tags})")
    except ImportError as e:
        print(json.dumps({"error": f"Cannot import ModelBroker: {e}"}), file=sys.stderr)
        return 1
    return 0


# ── Session Management (PLAN §5, §7) ─────────────────────────────

def cmd_session(args):
    """Session lifecycle via harness adapters (§5, §7)."""
    ensure_src_path()
    from agentic.implementations.harness_adapters import get_harness

    action = args.action
    harness = args.harness or "codex"
    adapter = get_harness(harness)

    if not adapter:
        available = list(get_all_harnesses_keys())
        print(json.dumps({"error": f"Unknown harness: {harness}", "available": available}), file=sys.stderr)
        return 1

    async def _run():
        if action == "start":
            project = args.project or None
            result = await adapter.start_session(harness, project=project)
        elif action == "end":
            session_id = args.session_id
            if not session_id:
                print("ERROR: --session-id required for 'end'", file=sys.stderr)
                return 1
            result = await adapter.end_session(session_id)
        else:  # list
            result = await adapter.list_sessions()

        if args.json or action == "list":
            print(json.dumps(result, indent=2))
        else:
            if isinstance(result, dict):
                for k, v in result.items():
                    if k != "data":  # skip verbose fields in default mode
                        print(f"  {k}: {v}")

    asyncio.run(_run())
    return 0


# ── Auth/Credential Management (PLAN §10.2) ──────────────────────

def cmd_auth(args):
    """Credential rotation via ExternalAccessBroker (§10.2)."""
    ensure_src_path()
    from agentic.implementations.git_and_external import ExternalAccessBroker

    service = args.service or "github"
    scope = args.scope or f"{service}.default"

    async def _run():
        broker = ExternalAccessBroker()
        result = await broker.rotate_credentials(service, scope)
        print(json.dumps(result, indent=2))

    asyncio.run(_run())
    return 0


# ── Scheduler Status (PLAN §11) ─────────────────────────────────

def cmd_scheduler(args):
    """Resource scheduler queries (§11)."""
    ensure_src_path()
    from agentic.control.scheduler import Scheduler, SchedulerState

    s = Scheduler(state=SchedulerState())
    action = args.action or "status"

    if action == "status":
        result = {
            "active_workloads": list(s.state.active_workloads.keys()),
            "state": {"total_cpu": s.state.total_cpu,
                      "allocated_cpu": s.state.allocated_cpu,
                      "total_memory_mb": s.state.total_memory_mb,
                      "allocated_memory_mb": s.state.allocated_memory_mb,
                      "total_gpu": s.state.total_gpu,
                      "mode": s.state.mode.value},
        }
    elif action == "stats":
        result = {
            "total_cpu": s.state.total_cpu,
            "allocated_cpu": s.state.allocated_cpu,
            "free_cpu": round(s.state.total_cpu - s.state.allocated_cpu, 2),
            "total_memory_mb": s.state.total_memory_mb,
            "allocated_memory_mb": s.state.allocated_memory_mb,
            "active_workloads": len(s.state.active_workloads),
        }
    else:
        print(f"Usage: agent control-plane scheduler status|stats", file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2))
    return 0


def get_all_harnesses_keys() -> list[str]:
    """Get all registered harness names."""
    ensure_src_path()
    try:
        from agentic.implementations.harness_adapters import get_all_harnesses
        return sorted(get_all_harnesses().keys())
    except ImportError:
        return ["codex", "claude", "hermes", "openhands"]  # fallback


def cmd_workspace(args):
    """Workspace lifecycle: create/switch/list/delete per user+project."""
    ensure_src_path()
    from agentic.models.identity import RuntimeContext, Project, AgentIdentity

    action = args.action
    user_id = args.user or os.environ.get("USER", "default")
    project = getattr(args, 'project', None)
    
    if action == "create":
        # Create new workspace directory structure
        
        base_dir_str = os.environ.get("AGENTIC_WORKSPACES_ROOT", "/srv/agentic/workspaces")
        base_dir = Path(base_dir_str)
        workspace_path = base_dir / user_id / (project or "personal")
        
        # Create directories: data/, code/, config/, logs/
        for subdir in ["data", "code", "config", "logs"]:
            (workspace_path / subdir).mkdir(parents=True, exist_ok=True)
        
        print(json.dumps({
            "action": "created",
            "path": str(workspace_path),
            "user_id": user_id,
            "project": project,
        }, indent=2))
    
    elif action == "list":
        # List existing workspaces
        base_dir_str = os.environ.get("AGENTIC_WORKSPACES_ROOT", "/srv/agentic/workspaces")
        base_dir = Path(base_dir_str)
        
        if not base_dir.exists():
            print(json.dumps({"workspaces": []}))
            return 0
        
        workspaces = []
        for user_dir in base_dir.iterdir():
            if user_dir.is_dir():
                for proj_dir in user_dir.iterdir():
                    if proj_dir.is_dir():
                        workspaces.append({
                            "user_id": user_dir.name,
                            "project": proj_dir.name,
                            "path": str(proj_dir),
                            "exists": True,
                        })
        
        print(json.dumps({"workspaces": workspaces}, indent=2))
    
    elif action == "switch":
        # Validate workspace exists (no-op in CLI; actual switch via API)
        base_dir_str = os.environ.get("AGENTIC_WORKSPACES_ROOT", "/srv/agentic/workspaces")
        base_dir = Path(base_dir_str)
        target = base_dir / user_id / (project or "personal")
        
        if target.exists():
            print(json.dumps({
                "action": "switched",
                "path": str(target),
                "user_id": user_id,
                "project": project,
            }, indent=2))
        else:
            print(json.dumps({"error": f"Workspace not found: {target}", "hint": "Run 'workspace create' first"}), file=sys.stderr)
            return 1
    
    elif action == "delete":
        base_dir_str = os.environ.get("AGENTIC_WORKSPACES_ROOT", "/srv/agentic/workspaces")
        base_dir = Path(base_dir_str)
        target = base_dir / user_id / (project or "personal")
        
        if target.exists():
            shutil.rmtree(target)
            print(json.dumps({"action": "deleted", "path": str(target)}, indent=2))
        else:
            print(json.dumps({"error": f"Workspace not found: {target}"}), file=sys.stderr)
            return 1
    
    return 0


def main_v2() -> int:
    """Enhanced main with migration router integration."""
    parser = argparse.ArgumentParser(
        description="v2 Control Plane CLI — model, session, auth, scheduler, workspace"
    )
    
    # Subparsers for top-level commands
    subparsers = parser.add_subparsers(dest="command")

    # model-route (kept from original)
    p_route = subparsers.add_parser("model-route", help="List models via ModelBroker (§6)")
    p_route.add_argument("--json", action="store_true")

    # session (kept from original)
    p_session = subparsers.add_parser("session", help="Session lifecycle (§5, §7)")
    p_session.add_argument("action", choices=["start", "end", "list"])
    p_session.add_argument("--harness", default="codex")
    p_session.add_argument("--project", default=None)
    p_session.add_argument("--session-id", default=None, dest="session_id")

    # auth (kept from original)
    p_auth = subparsers.add_parser("auth", help="Credential rotation (§10.2)")
    p_auth.add_argument("service", nargs="?", default="github")
    p_auth.add_argument("--scope", default=None)

    # scheduler (kept from original)
    p_sched = subparsers.add_parser("scheduler", help="Resource scheduler queries (§11)")
    p_sched.add_argument("action", nargs="?", default="status", choices=["status", "stats"])

    # workspace (NEW: workspace management §5.2, §13.2)
    p_workspace = subparsers.add_parser("workspace", help="Workspace lifecycle per user+project")
    p_workspace.add_argument("action", choices=["create", "list", "switch", "delete"])
    p_workspace.add_argument("--user", default=os.environ.get("USER", "default"))
    p_workspace.add_argument("--project", default=None)

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 1

    # Route through migration router (§13) for v1/v2 compatibility
    ensure_src_path()
    try:
        from agentic.migration.router import create_default_routes
        registry = create_default_routes()
        route = registry.get_route(args.command)
        
        if route and route.version_route == "v1":
            # Fall through to v1 implementation (shell scripts)
            print(f"DEBUG: Command '{args.command}' routes to v1 fallback")
    except ImportError:
        pass  # Migration router not available; use direct routing

    commands = {
        "model-route": cmd_model_route,
        "session": cmd_session,
        "auth": cmd_auth,
        "scheduler": cmd_scheduler,
        "workspace": cmd_workspace,
    }

    handler = commands.get(args.command)
    if not handler:
        print(f"Unknown command: {args.command}", file=sys.stderr)
        return 1

    return handler(args)


if __name__ == "__main__":
    sys.exit(main_v2())
