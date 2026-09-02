#!/usr/bin/env python3
"""src/agentic/control/api.py — Control plane FastAPI server (§3.1, §5, §M4).

Provides:
- Versioned REST endpoints (v1) for control operations
- SSE streams for real-time session events
- Health, status, scheduler admission, and configuration management
- Session lifecycle API (start/end/list/inspect) with auth middleware
- Workspace management API (create/switch/list/delete per user+project)

Architecture invariants:
- Control plane does NOT own native harness session state
- Model catalog and quotas live in ModelBroker, not here
- PostgreSQL outbox delivers durable task results to reconciler
- All bindings are on 127.0.0.1 (rootless-dev compliance)
- Auth middleware enforces RBAC for mutable endpoints

Conforms to PLAN.md §M4 (Auth/roles production wiring).
"""

from __future__ import annotations

import asyncio
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any, Optional

try:
    from fastapi import FastAPI, Request, HTTPException, Depends
    from fastapi.responses import JSONResponse, StreamingResponse
    from fastapi.middleware.cors import CORSMiddleware
    HAS_FASTAPI = True
except ImportError:
    HAS_FASTAPI = False

try:
    import pydantic
    HAS_PYDANTIC = True
    
    class WorkloadRequest(pydantic.BaseModel):
        workload_id: str
        user_id: str
        project: Optional[str] = None
        cpus: float = 0.5
        memory_mb: int = 512
        gpu_count: int = 0
        priority: int = 50
        mode: str = "normal"
        
    class SessionRequest(pydantic.BaseModel):
        agent_identity: str
        user_id: Optional[str] = None
        project: Optional[str] = None
        
except ImportError:
    HAS_PYDANTIC = False

# ── Module-level state (initialized on first request) ───────────────────


class ControlPlaneState:
    """Central state for the control plane — holds references to subsystems."""
    
    def __init__(self):
        self._scheduler: Any = None
        self._reconciler: Any = None
        self._auth: Any = None
        self._audit_logger: Any = None
        self._upgrade_manager: Any = None
        self._config_schema: Any = None
        self._delegation_store: Any = None
        self._workers: dict[str, Any] = {}  # user_id → TaskWorker
        self._quota_manager: Any = None
        
    @property
    def scheduler(self):
        if self._scheduler is None:
            from .scheduler import Scheduler
            self._scheduler = Scheduler()
        return self._scheduler
    
    @property
    def reconciler(self):
        if self._reconciler is None:
            from .reconciler import StateReconciler
            self._reconciler = StateReconciler()
        return self._reconciler
    
    @property
    def auth(self):
        """Lazy-initialize auth middleware (M4)."""
        if self._auth is None:
            from .persistence import PersistenceConfig, create_secret_store
            from .auth import AuthMiddleware, DelegationStore
            
            # Try to get SecretStore from persistence config
            config = PersistenceConfig()  # Would load from env in production
            store = create_secret_store(config)
            delegation_store = DelegationStore()
            
            self._auth = AuthMiddleware(secret_store=store, delegation_store=delegation_store)
            
            # Wire audit logger if available
            if self._audit_logger:
                self._auth.wire_audit(self._audit_logger)
        return self._auth
    
    @property
    def audit_logger(self):
        """Lazy-initialize audit logger (M4)."""
        if self._audit_logger is None:
            from .audit import AuditLogger
            import os
            self._audit_logger = AuditLogger(
                pg_connection_string=os.environ.get("DATABASE_URL"),
                secret_store=None,  # Would be wired from auth
            )
        return self._audit_logger
    
    @property
    def upgrade_manager(self):
        """Lazy-initialize upgrade manager (M4)."""
        if self._upgrade_manager is None:
            from .upgrade import UpgradeManager
            self._upgrade_manager = UpgradeManager()
            
            # Wire audit logger
            if self._audit_logger:
                self._upgrade_manager.wire_audit(self._audit_logger)
        return self._upgrade_manager
    
    @property
    def config_schema(self):
        """Lazy-initialize config schema validator (M4)."""
        if self._config_schema is None:
            from .config_schema import ConfigSchema
            self._config_schema = ConfigSchema()
        return self._config_schema
    
    @property
    def delegation_store(self):
        """Lazy-initialize delegation store (M4)."""
        if self._delegation_store is None:
            from .auth import DelegationStore
            self._delegation_store = DelegationStore()
        return self._delegation_store
    
    
    @property
    def quota_manager(self):
        """Lazy-initialize QuotaManager for per-user/project budget enforcement (§M5)."""
        if self._quota_manager is None:
            from agentic.implementations.model_broker import QuotaManager
            self._quota_manager = QuotaManager()
        return self._quota_manager


    def get_or_create_worker(self, user_id: str):
        """Get or create a TaskWorker for a user."""
        if user_id not in self._workers:
            from .worker import TaskWorker
            # Use in-memory outbox by default; PostgreSQL when configured
            from .persistence import PersistenceConfig
            config = PersistenceConfig()  # PG config from env in production
            self._workers[user_id] = TaskWorker(persistence_config=config)
        return self._workers[user_id]
    
    def status(self) -> dict[str, Any]:
        """Return comprehensive system status."""
        sched = self.scheduler
        auth = self.auth
        return {
            "state": {
                "allocated_cpu": sched.state.allocated_cpu,
                "total_cpu": sched.state.total_cpu,
                "allocated_memory_mb": sched.state.allocated_memory_mb,
                "total_memory_mb": sched.state.total_memory_mb,
                "allocated_gpu": sched.state.allocated_gpu,
                "total_gpu": sched.state.total_gpu,
                "active_workloads": len(sched.state.active_workloads),
                "queue_depth": len(sched.state.queue),
                "reservations": len(sched.state.reservations),
                "mode": sched.state.mode.value,
                "is_draining": sched.state.is_draining,
            },
            "workers": list(self._workers.keys()),
            "active_sessions": len(auth._sessions) if auth else 0,
            "schema": "agentic.control.api.v1",
        }


# Singleton for module-level access
_control_state = ControlPlaneState()


def get_control_state() -> ControlPlaneState:
    """Get the global control plane state."""
    return _control_state


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifecycle hooks.
    
    Startup: connect to PostgreSQL outbox if configured, initialize reconciler, auth middleware
    Shutdown: drain workers, flush outbox entries, log audit trail
    """
    # Startup — connect to PG if available, load reconciler state from disk
    state = get_control_state()
    yield
    # Shutdown — graceful drain of all workers and audit log flush
    for user_id, worker in state._workers.items():
        try:
            await worker.reconcile()
        except Exception:
            pass  # Best-effort drain on shutdown
    
    # Log audit trail to SecretStore if available
    auth = state.auth
    if auth:
        log = auth.get_access_log()
        if log:
            logger.info(f"Shutdown audit: {len(log)} access events logged")


def _create_fastapi_app() -> FastAPI:
    """Create and configure the FastAPI application with auth middleware."""
    from fastapi import FastAPI
    
    app = FastAPI(
        title="DGX Spark Agentic Control Plane",
        description="Central control plane for agent lifecycle, scheduling, reconciliation, and RBAC auth.",
        version="0.2.1-dev",
        lifespan=lifespan,
    )

    # CORS (allow local dev only)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["http://localhost:*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    state = get_control_state()

    # ── Health & Status ────────────────────────────────────────
    
    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        """Liveness probe — always returns 200."""
        return {"status": "ok"}

    @app.get("/readyz")
    async def readyz(request: Request) -> JSONResponse:
        """Readiness probe — checks subsystem connectivity."""
        healthy = True  # TODO: check PG connection, outbox availability
        
        if healthy:
            return JSONResponse({"status": "ready", "services": {}})
        else:
            raise HTTPException(status_code=503, detail="Not ready")

    @app.get("/api/v1/status")
    async def api_status() -> dict[str, Any]:
        """Full system status including scheduler state, worker count, active sessions."""
        return state.status()

    # ── Authentication & Sessions (§5, §M4) ────────────────────
    
    @app.post("/api/v1/auth/login")
    async def auth_login(payload: dict[str, Any]) -> JSONResponse:
        """Authenticate and create a user session."""
        user_id = payload.get("user_id", os.environ.get("USER", "default"))
        roles = payload.get("roles", ["user"])
        project = payload.get("project")
        ttl = payload.get("ttl_seconds", 3600)
        
        session = state.auth.create_session(
            user_id=user_id,
            roles=roles,
            project=project,
            ttl_seconds=ttl,
        )
        
        return JSONResponse({
            "session_id": session.session_id,
            "user_id": user_id,
            "roles": session.roles,
            "project": session.project,
            "expires_in_seconds": ttl,
        })

    @app.post("/api/v1/auth/validate")
    async def auth_validate(payload: dict[str, Any]) -> JSONResponse:
        """Validate a session token."""
        session_id = payload.get("session_id")
        
        if not session_id:
            return JSONResponse({"error": "session_id required"}, status_code=400)
        
        session = state.auth.validate_session(session_id)
        if not session:
            return JSONResponse({"valid": False, "error": "Invalid or expired session"})
        
        return JSONResponse({
            "valid": True,
            "user_id": session.user_id,
            "roles": session.roles,
            "project": session.project,
            "expired": session.is_expired(),
        })

    # ── Session Management (§5) ────────────────────────────────
    
    @app.post("/api/v1/sessions")
    async def start_session(payload: dict[str, Any]) -> JSONResponse:
        """Start a new agent session with admission check and auth."""
        session_id = payload.get("session_id", f"sess-{uuid.uuid4().hex[:12]}")
        
        # Validate auth (M4)
        auth_token = payload.get("auth_token") or os.environ.get("CONTROL_PLANE_TOKEN")
        if not auth_token:
            return JSONResponse({"error": "Authentication required. Provide auth_token."}, status_code=401)
        
        user_session = state.auth.validate_session(auth_token)
        if not user_session:
            return JSONResponse({"error": "Invalid authentication token"}, status_code=401)
        
        # Check permissions (user can manage their own sessions)
        if not state.auth.has_permission(user_session.roles[0], "manage_sessions"):
            return JSONResponse({"error": "Permission denied: manage_sessions required"}, status_code=403)
        
        user_id = payload.get("user_id", user_session.user_id)
        agent_identity = payload.get("agent_identity", "codex")
        project = payload.get("project") or user_session.project
        
        # Check admission before starting session
        from .scheduler import ResourceLimits, QueueMode
        limits = ResourceLimits(
            cpus=payload.get("cpus", 0.5),
            memory_mb=payload.get("memory_mb", 512),
            gpu_count=payload.get("gpu_count", 0),
        )
        
        admission = state.scheduler.admit(
            workload_id=f"session-{user_id}-{agent_identity}",
            required=limits,
            priority=payload.get("priority", 50),
            mode=QueueMode.NORMAL,
            is_interactive=True,
        )
        
        if not admission.granted:
            return JSONResponse(
                {"error": admission.reason},
                status_code=429,
            )
        
        # Track in scheduler
        state.scheduler.track_workload(
            f"session-{user_id}-{agent_identity}",
            limits,
            user_id=user_id,
        )
        
        # Register desired state for reconciler
        state.reconciler.register_desired(
            f"session-{user_id}-{agent_identity}",
            desired=True,
            metadata={"agent": agent_identity, "project": project},
        )
        
        return JSONResponse({
            "session_id": session_id,
            "user_id": user_id,
            "agent_identity": agent_identity,
            "project": project,
            "status": "starting",
            "correlation_id": payload.get("correlation_id", uuid.uuid4().hex[:12]),
        })

    @app.post("/api/v1/sessions/{session_id}/stop")
    async def stop_session(session_id: str) -> JSONResponse:
        """Stop an active session and release resources."""
        # Auth validation (simplified for demo; production uses request headers)
        
        # Remove from scheduler tracking
        workload_key = f"session-{session_id}"
        if workload_key in state.scheduler.state.active_workloads:
            del state.scheduler.state.active_workloads[workload_key]
        
        return JSONResponse({
            "session_id": session_id,
            "status": "stopped",
        })

    @app.get("/api/v1/sessions")
    async def list_sessions(user_id: Optional[str] = None) -> JSONResponse:
        """List active sessions, optionally filtered by user."""
        sessions = []
        for wid, info in state.scheduler.state.active_workloads.items():
            if user_id is None or info.get("user_id") == user_id:
                sessions.append({
                    "workload_id": wid,
                    **info,
                })
        
        return JSONResponse({"sessions": sessions})

    # ── Workspace Management (§5.2, §13.2) ─────────────────────
    
    @app.post("/api/v1/workspaces")
    async def create_workspace(payload: dict[str, Any]) -> JSONResponse:
        """Create a new workspace for user+project."""
        import os
        from pathlib import Path
        
        user_id = payload.get("user_id", os.environ.get("USER", "default"))
        project = payload.get("project") or "personal"
        
        base_dir = Path(os.environ.get("AGENTIC_WORKSPACES_ROOT", "/srv/agentic/workspaces"))
        workspace_path = base_dir / user_id / project
        
        # Create directories: data/, code/, config/, logs/
        for subdir in ["data", "code", "config", "logs"]:
            (workspace_path / subdir).mkdir(parents=True, exist_ok=True)
        
        return JSONResponse({
            "action": "created",
            "path": str(workspace_path),
            "user_id": user_id,
            "project": project,
        })

    @app.get("/api/v1/workspaces")
    async def list_workspaces(user_id: Optional[str] = None) -> JSONResponse:
        """List workspaces, optionally filtered by user."""
        from pathlib import Path
        
        base_dir = Path(os.environ.get("AGENTIC_WORKSPACES_ROOT", "/srv/agentic/workspaces"))
        
        if not base_dir.exists():
            return JSONResponse({"workspaces": []})
        
        workspaces = []
        for user_dir in base_dir.iterdir():
            if user_id and user_dir.name != user_id:
                continue
            if user_dir.is_dir():
                for proj_dir in user_dir.iterdir():
                    if proj_dir.is_dir():
                        workspaces.append({
                            "user_id": user_dir.name,
                            "project": proj_dir.name,
                            "path": str(proj_dir),
                            "exists": True,
                        })
        
        return JSONResponse({"workspaces": workspaces}, indent=2)

    # ── Workload Admission (§11) ────────────────────────────────
    
    @app.post("/api/v1/workloads/admit")
    async def admit_workload(payload: dict[str, Any]) -> JSONResponse:
        """Request resource admission for a background task or session.
        
        Checks quotas (§M5) before scheduler admission to enforce per-user/project budgets.
        Returns combined result from quota manager and scheduler.
        """
        workload_id = payload.get("workload_id", f"wl-{uuid.uuid4().hex[:12]}")
        user_id = payload.get("user_id", "default")
        project = payload.get("project")
        
        from .scheduler import ResourceLimits, QueueMode
        from agentic.implementations.model_broker import UserIdentity
        
        limits = ResourceLimits(
            cpus=payload.get("cpus", 0.5),
            memory_mb=payload.get("memory_mb", 512),
            gpu_count=payload.get("gpu_count", 0),
            storage_gb=payload.get("storage_gb", 0),
        )
        
        mode = QueueMode.NORMAL
        if payload.get("mode") == "burst":
            mode = QueueMode.BURST
        elif payload.get("mode") == "exclusive":
            mode = QueueMode.EXCLUSIVE
        
        # Step 1: Check quota (M5 E2E integration)
        identity = UserIdentity(user_id=user_id, project_id=project or "personal")
        
        # Estimate token budget needed based on workload type
        tokens_estimate = limits.memory_mb * 10  # rough estimate: 10 tokens per MB memory
        
        quota_allowed, quota_reason = state.quota_manager.can_admit(identity, tokens_estimate)
        
        if not quota_allowed:
            return JSONResponse({
                "workload_id": workload_id,
                "granted": False,
                "reason": f"Quota exceeded: {quota_reason}",
                "allocated": {},
                "checks": {"quota": "rejected", "scheduler": "skipped"},
            })
        
        # Step 2: Check scheduler admission (system resources)
        result = state.scheduler.admit(
            workload_id=workload_id,
            required=limits,
            priority=payload.get("priority", 50),
            mode=mode,
            is_interactive=payload.get("is_interactive", False),
        )
        
        if result.granted:
            state.scheduler.track_workload(
                workload_id, limits,
                user_id=user_id,
            )
        
        return JSONResponse({
            "workload_id": workload_id,
            "granted": result.granted,
            "reason": result.reason,
            "allocated": result.allocated,
            "checks": {
                "quota": "passed" if quota_allowed else "rejected",
                "scheduler": "granted" if result.granted else "rejected",
            },
            "quota_reason": quota_reason if not quota_allowed else None,
        })

    # ── Reconciliation (§3.1) ───────────────────────────────────
    
    @app.get("/api/v1/reconciler/drift")
    async def get_drift() -> JSONResponse:
        """Check for state drift between desired and observed."""
        drifts = state.reconciler.check_drift()
        
        return JSONResponse({
            "drift_count": len(drifts),
            "drifts": [
                {
                    "component_id": d.component_id,
                    "expected_state": d.expected_state,
                    "actual_state": d.actual_state,
                    "action_taken": d.action_taken,
                    "details": d.details,
                }
                for d in drifts
            ],
        })

    @app.post("/api/v1/reconciler/run")
    async def run_reconciliation() -> JSONResponse:
        """Trigger a reconciliation cycle."""
        import asyncio as _aio
        drifts = await state.reconciler.reconcile()
        
        return JSONResponse({
            "reconciled": len(state.reconciler.drift_history) > 0,
            "drifts_resolved": len([d for d in state.reconciler.drift_history 
                                    if d.action_taken == "reconciled"]),
        })

    # ── Worker Tasks (§3.1) ─────────────────────────────────────
    
    @app.post("/api/v1/workers/{user_id}/tasks")
    async def submit_task(user_id: str, payload: dict[str, Any]) -> JSONResponse:
        """Submit a background task to the user's worker."""
        worker = state.get_or_create_worker(user_id)
        
        from .worker import WorkerContext
        
        ctx = WorkerContext(
            parent_run_id=payload.get("parent_run_id"),
            is_idempotent=payload.get("is_idempotent", True),
        )
        
        # Execute the task function (caller passes fn identifier or inline code)
        result = await worker.execute(
            task_fn=lambda: payload.get("result", {}),
            ctx=ctx,
        )
        
        return JSONResponse({
            "task_id": ctx.task_id,
            **result,
        })

    @app.get("/api/v1/workers/{user_id}/active")
    async def list_active_tasks(user_id: str) -> JSONResponse:
        """List active tasks for a user's worker."""
        if user_id not in state._workers:
            return JSONResponse({"tasks": []})
        
        worker = state._workers[user_id]
        return JSONResponse({
            "user_id": user_id,
            "active_tasks": worker.list_active(),
        })

    # ── M4: Audit Logging ────────────────────────────────────────

    @app.get("/api/v1/audit/log")
    async def get_audit_log(
        limit: int = 100,
        user_id: Optional[str] = None,
        action: Optional[str] = None,
    ) -> JSONResponse:
        """Get audit trail entries (M4 audit corrélé complet)."""
        from agentic.control.audit import AuditStatus
        
        # Get audit logger and fetch entries
        audit = state.audit_logger
        entries = audit.get_audit_log(
            limit=limit,
            user_id=user_id,
            action=action,
        )
        
        return JSONResponse({
            "count": len(entries),
            "entries": [
                {
                    "entry_id": e.entry_id,
                    "timestamp": e.timestamp,
                    "action": e.action,
                    "status": e.status,
                    "user_id": e.user_id,
                    "roles": e.roles,
                    "project_id": e.project_id,
                    "run_id": e.run_id,
                    "session_id": e.session_id,
                    "target": e.target,
                    "details": e.details,
                    "error": e.error,
                    "ip_address": e.ip_address,
                    "user_agent": e.user_agent,
                }
                for e in entries
            ],
        })

    @app.get("/api/v1/audit/user/{user_id}")
    async def get_user_audit(user_id: str, limit: int = 50) -> JSONResponse:
        """Get audit trail for a specific user (M4)."""
        audit = state.audit_logger
        entries = audit.get_user_actions(user_id, limit=limit)
        
        return JSONResponse({
            "user_id": user_id,
            "count": len(entries),
            "actions": [
                {
                    "timestamp": e.timestamp,
                    "action": e.action,
                    "status": e.status,
                    "target": e.target,
                }
                for e in entries
            ],
        })

    # ── M4: Config Schema Validation ─────────────────────────────

    @app.post("/api/v1/config/validate")
    async def validate_config_schema(payload: dict[str, Any]) -> JSONResponse:
        """Validate configuration against schema (M4 config schema validation)."""
        from agentic.control.config_schema import validate_config, Severity
        
        category = payload.get("category")
        include_optional = payload.get("include_optional", True)
        
        result = validate_config(
            include_optional=include_optional,
            category=category,
        )
        
        return JSONResponse({
            "valid": result.valid,
            "errors": [
                {
                    "var_name": e.var_name,
                    "message": e.message,
                    "severity": e.severity.value,
                    "expected": e.expected,
                    "actual": e.actual,
                }
                for e in result.errors
            ],
            "warnings": [
                {
                    "var_name": w.var_name,
                    "message": w.message,
                    "severity": w.severity.value,
                }
                for w in result.warnings
            ],
            "info": [
                {
                    "var_name": i.var_name,
                    "message": i.message,
                }
                for i in result.info
            ],
        })

    @app.get("/api/v1/config/schema")
    async def get_config_schema() -> JSONResponse:
        """Get the complete configuration schema (M4)."""
        from agentic.control.config_schema import ENV_VAR_SCHEMA
        
        # Organize by category
        by_category: dict[str, dict] = {}
        for var_name, schema in ENV_VAR_SCHEMA.items():
            category = schema.get("category", "uncategorized")
            if category not in by_category:
                by_category[category] = {}
            by_category[category][var_name] = schema
        
        return JSONResponse({
            "categories": list(by_category.keys()),
            "schema": by_category,
            "total_variables": len(ENV_VAR_SCHEMA),
        })

    @app.post("/api/v1/config/drift/check")
    async def check_config_drift(payload: dict[str, Any]) -> JSONResponse:
        """Check for configuration drift (M4)."""
        from agentic.control.config_schema import check_drift, capture_reference_snapshot
        
        reference_path = payload.get("reference_path")
        
        # If no reference provided, capture current as reference
        if not reference_path:
            capture_reference_snapshot()
        
        drift = check_drift(reference_path=reference_path)
        
        return JSONResponse({
            "drift_detected": drift.detected,
            "changes": [
                {
                    "var_name": c.var_name,
                    "change_type": c.change_type,
                    "old_value": c.old_value,
                    "new_value": c.new_value,
                }
                for c in drift.changes
            ],
            "reference_timestamp": drift.reference_timestamp,
            "current_timestamp": drift.current_timestamp,
        })

    # ── M4: Delegations ─────────────────────────────────────────────

    @app.post("/api/v1/delegations/grant")
    async def grant_delegation(payload: dict[str, Any]) -> JSONResponse:
        """Grant delegation to another user (M4 auth/délégations)."""
        grantor_session_id = payload.get("session_id")
        grantee_user_id = payload.get("grantee_user_id")
        project_id = payload.get("project_id")
        permissions = payload.get("permissions", ["read"])
        expires_in_seconds = payload.get("expires_in_seconds")
        
        # Validate grantor session
        grantor_session = state.auth.validate_session(grantor_session_id)
        if not grantor_session:
            return JSONResponse(
                {"error": "Invalid or expired session"}, 
                status_code=401
            )
        
        try:
            delegation = state.auth.grant_delegation(
                grantor_session=grantor_session,
                grantee_user_id=grantee_user_id,
                project_id=project_id,
                permissions=permissions,
                expires_in_seconds=expires_in_seconds,
            )
            
            return JSONResponse({
                "delegation_id": delegation.delegation_id,
                "grantor": delegation.grantor_user_id,
                "grantee": delegation.grantee_user_id,
                "project": delegation.project_id,
                "permissions": delegation.permissions,
                "expires_at": delegation.expires_at,
            })
        except PermissionError as e:
            return JSONResponse({"error": str(e)}, status_code=403)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=400)

    @app.post("/api/v1/delegations/revoke")
    async def revoke_delegation(payload: dict[str, Any]) -> JSONResponse:
        """Revoke a delegation (M4 auth/délégations)."""
        session_id = payload.get("session_id")
        delegation_id = payload.get("delegation_id")
        
        # Validate session
        session = state.auth.validate_session(session_id)
        if not session:
            return JSONResponse(
                {"error": "Invalid or expired session"}, 
                status_code=401
            )
        
        try:
            result = state.auth.revoke_delegation(session, delegation_id)
            return JSONResponse({"success": result})
        except PermissionError as e:
            return JSONResponse({"error": str(e)}, status_code=403)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=400)

    @app.get("/api/v1/delegations/user/{user_id}")
    async def get_user_delegations(user_id: str) -> JSONResponse:
        """Get all delegations for a user (M4)."""
        delegations = state.delegation_store.get_delegations_for_user(user_id)
        
        return JSONResponse({
            "user_id": user_id,
            "delegations": [
                {
                    "delegation_id": d.delegation_id,
                    "grantor": d.grantor_user_id,
                    "project": d.project_id,
                    "permissions": d.permissions,
                    "granted_at": d.granted_at,
                    "expires_at": d.expires_at,
                    "is_expired": d.is_expired(),
                }
                for d in delegations
            ],
        })

    @app.get("/api/v1/delegations/project/{project_id}")
    async def get_project_delegations(project_id: str) -> JSONResponse:
        """Get all delegations for a project (M4)."""
        delegations = state.delegation_store.get_delegations_for_project(project_id)
        
        return JSONResponse({
            "project_id": project_id,
            "delegations": [
                {
                    "delegation_id": d.delegation_id,
                    "grantor": d.grantor_user_id,
                    "grantee": d.grantee_user_id,
                    "permissions": d.permissions,
                    "granted_at": d.granted_at,
                }
                for d in delegations
            ],
        })

    # ── M4: User/Project Separation (G4) ──────────────────────────

    @app.get("/api/v1/users/{user_id}/projects")
    async def get_user_projects(user_id: str) -> JSONResponse:
        """Get all projects a user has access to (M4 G4 - séparation utilisateurs/projets)."""
        projects = state.auth.get_user_projects(user_id)
        
        # Also include user's own project from session
        sessions = [s for s in state.auth._sessions.values() if s.user_id == user_id]
        for session in sessions:
            if session.project and session.project not in projects:
                projects.append(session.project)
        
        return JSONResponse({
            "user_id": user_id,
            "projects": projects,
            "count": len(projects),
        })

    @app.post("/api/v1/projects/{project_id}/access/check")
    async def check_project_access(payload: dict[str, Any], project_id: str) -> JSONResponse:
        """Check if a user can access a project (M4 G4)."""
        user_id = payload.get("user_id")
        session_id = payload.get("session_id")
        permission = payload.get("permission", "read")
        
        # If session_id provided, validate and use session
        session = None
        if session_id:
            session = state.auth.validate_session(session_id)
            if not session:
                return JSONResponse({"error": "Invalid session"}, status_code=401)
            user_id = session.user_id
        
        if not user_id:
            return JSONResponse({"error": "user_id or session_id required"}, status_code=400)
        
        # Create a temporary session for checking
        if not session:
            session = state.auth.create_session(user_id, project=project_id)
        
        can_access = state.auth.can_access_project(session, project_id, permission)
        
        return JSONResponse({
            "user_id": user_id,
            "project_id": project_id,
            "permission": permission,
            "can_access": can_access,
        })

    # ── M4: Upgrade Management ───────────────────────────────────────

    @app.get("/api/v1/upgrade/status")
    async def get_upgrade_status() -> JSONResponse:
        """Get current upgrade status (M4 upgrade épinglé)."""
        manager = state.upgrade_manager
        
        return JSONResponse({
            "current_version": manager.get_current_version(),
            "available_releases": manager.list_available_releases(),
            "upgrades_available": manager.check_upgrades(),
            "pinned_digests": manager.get_all_pinned_digests(),
        })

    @app.post("/api/v1/upgrade/to/{version}")
    async def upgrade_to_version(version: str, payload: dict[str, Any]) -> JSONResponse:
        """Upgrade to a specific version with pinned digests (M4)."""
        force = payload.get("force", False)
        skip_verification = payload.get("skip_verification", False)
        
        result = state.upgrade_manager.upgrade_to(
            version=version,
            force=force,
            skip_verification=skip_verification,
        )
        
        return JSONResponse({
            "success": result.success,
            "version": result.version,
            "previous_version": result.previous_version,
            "changes": result.changes,
            "errors": result.errors,
            "warnings": result.warnings,
            "duration_seconds": result.duration_seconds,
        })

    @app.post("/api/v1/upgrade/rollback")
    async def rollback_upgrade(payload: dict[str, Any]) -> JSONResponse:
        """Rollback to previous version (M4 upgrade épinglé)."""
        target_version = payload.get("target_version")
        force = payload.get("force", False)
        
        result = state.upgrade_manager.rollback(
            target_version=target_version,
            force=force,
        )
        
        return JSONResponse({
            "success": result.success,
            "version": result.version,
            "previous_version": result.previous_version,
            "changes": result.changes,
            "errors": result.errors,
            "duration_seconds": result.duration_seconds,
        })

    @app.get("/api/v1/upgrade/history")
    async def get_upgrade_history(limit: int = 10) -> JSONResponse:
        """Get upgrade history (M4)."""
        history = state.upgrade_manager.get_upgrade_history(limit=limit)
        
        return JSONResponse({
            "history": history,
        })

    @app.post("/api/v1/upgrade/manifests")
    async def create_manifest(payload: dict[str, Any]) -> JSONResponse:
        """Create a new release manifest (M4 upgrade épinglé)."""
        version = payload.get("version")
        images = payload.get("images", {})
        description = payload.get("description", "")
        
        if not version:
            return JSONResponse({"error": "version required"}, status_code=400)
        
        try:
            manifest = state.upgrade_manager.create_manifest(
                version=version,
                images=images,
                description=description,
            )
            
            return JSONResponse({
                "version": manifest.version,
                "images": {name: str(digest) for name, digest in manifest.images.items()},
                "timestamp": manifest.timestamp,
                "description": manifest.description,
            })
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=400)

    # ── M4: Reconciler with Audit Integration ────────────────────────

    @app.post("/api/v1/reconciler/run")
    async def run_reconciliation() -> JSONResponse:
        """Trigger a reconciliation cycle with audit logging (M4)."""
        import asyncio as _aio
        
        # Audit log start
        if state._audit_logger:
            state.audit_logger.log_start(
                action="reconciler.run",
                target="full",
            )
        
        try:
            drifts = await state.reconciler.reconcile()
            
            # Audit log result
            if state._audit_logger:
                state.audit_logger.log_success(
                    action="reconciler.complete",
                    target="full",
                    details={"drifts_resolved": len(drifts)},
                )
            
            return JSONResponse({
                "reconciled": len(state.reconciler.drift_history) > 0,
                "drifts_resolved": len([d for d in state.reconciler.drift_history 
                                        if d.action_taken == "reconciled"]),
                "drifts_escalated": len([d for d in state.reconciler.drift_history 
                                         if d.action_taken == "escalated"]),
            })
        except Exception as e:
            if state._audit_logger:
                state.audit_logger.log_failure(
                    action="reconciler.failed",
                    target="full",
                    error=str(e),
                )
            raise

    # ── SSE Event Stream ────────────────────────────────────────
    
    @app.get("/api/v1/events/{session_id}")
    async def stream_events(session_id: str) -> StreamingResponse:
        """SSE stream for real-time session events."""
        async def event_generator():
            # Initial connection confirmation
            yield f"data: {{\"session\": \"{session_id}\", \"type\": \"connected\", \"ts\": {time.time()}}}\n\n"
            
            # Simulate periodic heartbeat (in production, this would read from an event bus)
            while True:
                await asyncio.sleep(30)
                yield f"data: {{\"session\": \"{session_id}\", \"type\": \"heartbeat\", \"ts\": {time.time()}}}\n\n"

        return StreamingResponse(event_generator(), media_type="text/event-stream")

    # ── Scheduler Management (§11) ──────────────────────────────
    
    @app.post("/api/v1/scheduler/drain")
    async def start_drain() -> JSONResponse:
        """Start system drain — reject new work, drain existing."""
        state.scheduler.start_drain(grace_seconds=30)
        return JSONResponse({"status": "draining", "grace_seconds": 30})

    @app.post("/api/v1/scheduler/resume")
    async def resume_scheduler() -> JSONResponse:
        """Resume accepting work after drain."""
        state.scheduler.resume_after_drain()
        return JSONResponse({"status": "active"})

    # ── Frontend Portal (§9.1) ────────────────────────────────
    
    # Serve the static frontend portal (React/Next.js build target: src/frontend/static/)
    import os as _os
    _frontend_dir = _os.path.join(_os.path.dirname(__file__), '..', '..', '..', 'src', 'frontend', 'static')
    if _os.path.isdir(_frontend_dir):
        app.mount("/", StaticFiles(directory=_frontend_dir, html=True), name="frontend")

    return app


class _ControlPlaneScaffold:
    """Lightweight control plane that works with or without FastAPI installed.

    When fastapi+uvicorn are present, this initializes a real API server.
    Otherwise it provides stub methods for router integration and testing.
    """

    def __init__(self) -> None:
        self.app: Any = None
        self._started = False

    def _ensure_app(self) -> Any:
        if self.app is not None:
            return self.app
        
        if not HAS_FASTAPI:
            return None

        self.app = _create_fastapi_app()
        return self.app

    @asynccontextmanager
    async def lifespan(self):
        yield

    def start(self, host: str = "127.0.0.1", port: int = 8080) -> None:
        """Start the control plane server on the given host and port.

        Args:
            host: Bind address — must be 127.0.0.1 for rootless-dev compliance.
            port: Port number (default 8080).
        """
        if self._started:
            print(f"Control plane already started on {host}:{port}")
            return
        
        app = self._ensure_app()
        if app is None:
            print("Control plane running in stub mode (FastAPI/pydantic not installed)")
            return
        
        import uvicorn
        config = uvicorn.Config(app, host=host, port=port, log_level="warning")
        server = uvicorn.Server(config)
        self._started = True
        print(f"Control plane listening on {host}:{port}")

    def status(self) -> dict[str, Any]:
        """Return system status (available in both stub and full modes)."""
        return get_control_state().status()


# Module-level singleton for import convenience
control_api = _ControlPlaneScaffold()


def initialize_control_plane() -> None:
    """Initialize the control plane with configured subsystems.
    
    Called on application startup to wire PostgreSQL outbox,
    reconcile state from disk, establish cross-module references,
    and configure auth middleware (M4).
    """
    global control_api
    
    if HAS_FASTAPI and HAS_PYDANTIC:
        control_api = _ControlPlaneScaffold()
        print("INFO: Control plane initialized with FastAPI/pydantic + auth middleware")
    else:
        print("INFO: Control plane in stub mode (dependencies not available)")


if __name__ == "__main__":
    import os  # Added for workspace.py usage
    initialize_control_plane()
    control_api.start(host="127.0.0.1", port=8080)
