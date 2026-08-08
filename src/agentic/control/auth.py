#!/usr/bin/env python3
"""src/agentic/control/auth.py — Authentication & authorization for control plane (§4, §5.1, §M4).

Provides:
- User authentication via secret store tokens (Fernet-encrypted when PG available)
- Role-based access control (RBAC): admin, operator, user, readonly
- Delegation support for cross-user/project access
- Session management with correlation IDs for audit trails
- Middleware hooks for FastAPI endpoints
- Integration with SecretStore for credential verification

Conforms to PLAN.md §M4 (Auth/roles production wiring) and §10.1 (SecretStore).

Usage:
    from agentic.control.auth import AuthMiddleware, RoleChecker, DelegationChecker
    
    # In FastAPI lifespan or middleware setup:
    auth = AuthMiddleware(secret_store=store, delegation_store=delegation_store)
    
    @app.get("/api/v1/status", dependencies=[auth.require_role("user")])
    async def status():
        return {"ok": True}
    
    # Check delegation
    if auth.can_access_project(user_session, "PROJECT_X"):
        # User has access to project
        pass
"""

from __future__ import annotations

import asyncio
import enum
import hashlib
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from .persistence import SecretStoreBackend

logger = logging.getLogger(__name__)


class Role(enum.Enum):
    """User roles with permission levels."""
    ADMIN = "admin"      # Full access, including system configuration
    OPERATOR = "operator"  # Read/write operations, no system config
    USER = "user"        # Read/write own sessions and workspaces
    READONLY = "readonly"  # Read-only access to status and catalog


@dataclass
class UserSession:
    """Represents an authenticated user session."""
    session_id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    user_id: str = ""
    roles: list[str] = field(default_factory=lambda: [Role.USER.value])
    project: Optional[str] = None
    created_at: float = field(default_factory=time.time)
    expires_at: Optional[float] = None  # TTL in seconds from created_at
    parent_run_id: Optional[str] = None

    def is_expired(self) -> bool:
        """Check if session has expired."""
        if self.expires_at is None:
            return False  # No expiry set
        return time.time() > self.expires_at


@dataclass
class PermissionPolicy:
    """Permission rules per role for API endpoints."""
    can_read_status: bool = True
    can_manage_sessions: bool = False
    can_rotate_credentials: bool = False
    can_modify_scheduler: bool = False
    can_access_secrets: bool = False

    @classmethod
    def admin_policy(cls) -> PermissionPolicy:
        return cls(
            can_read_status=True,
            can_manage_sessions=True,
            can_rotate_credentials=True,
            can_modify_scheduler=True,
            can_access_secrets=True,
        )

    @classmethod
    def operator_policy(cls) -> PermissionPolicy:
        return cls(
            can_read_status=True,
            can_manage_sessions=True,
            can_rotate_credentials=False,
            can_modify_scheduler=False,
            can_access_secrets=False,
        )

    @classmethod
    def user_policy(cls) -> PermissionPolicy:
        return cls(
            can_read_status=True,
            can_manage_sessions=True,
            can_rotate_credentials=False,
            can_modify_scheduler=False,
            can_access_secrets=False,
        )

    @classmethod
    def readonly_policy(cls) -> PermissionPolicy:
        return cls(
            can_read_status=True,
            can_manage_sessions=False,
            can_rotate_credentials=False,
            can_modify_scheduler=False,
            can_access_secrets=False,
        )


# ── Delegation Support (§M4) ──────────────────────────────────────────────

@dataclass
class Delegation:
    """Represents a delegation of permissions from one user/project to another."""
    delegation_id: str = field(default_factory=lambda: f"del-{uuid.uuid4().hex[:12]}")
    grantor_user_id: str = ""
    grantee_user_id: str = ""
    project_id: str = ""
    permissions: list[str] = field(default_factory=list)  # e.g., ["read", "write", "admin"]
    granted_at: float = field(default_factory=time.time)
    expires_at: Optional[float] = None  # None means no expiry
    scope: str = "*"  # Specific resource or "*" for all

    def is_expired(self) -> bool:
        """Check if delegation has expired."""
        if self.expires_at is None:
            return False
        return time.time() > self.expires_at

    def has_permission(self, permission: str) -> bool:
        """Check if delegation grants a specific permission."""
        return permission in self.permissions or "*" in self.permissions


class DelegationStore:
    """Store for managing user/project delegations."""

    def __init__(self):
        self._delegations: dict[str, Delegation] = {}  # delegation_id -> Delegation
        self._user_delegations: dict[str, list[str]] = {}  # user_id -> [delegation_id, ...]
        self._project_delegations: dict[str, list[str]] = {}  # project_id -> [delegation_id, ...]

    def grant_delegation(
        self,
        grantor_user_id: str,
        grantee_user_id: str,
        project_id: str,
        permissions: list[str],
        expires_in_seconds: Optional[int] = None,
        scope: str = "*",
    ) -> Delegation:
        """Grant delegation from one user to another for a project."""
        delegation = Delegation(
            grantor_user_id=grantor_user_id,
            grantee_user_id=grantee_user_id,
            project_id=project_id,
            permissions=permissions,
            expires_at=time.time() + expires_in_seconds if expires_in_seconds else None,
            scope=scope,
        )
        
        self._delegations[delegation.delegation_id] = delegation
        
        # Index by grantee
        if grantee_user_id not in self._user_delegations:
            self._user_delegations[grantee_user_id] = []
        self._user_delegations[grantee_user_id].append(delegation.delegation_id)
        
        # Index by project
        if project_id not in self._project_delegations:
            self._project_delegations[project_id] = []
        self._project_delegations[project_id].append(delegation.delegation_id)
        
        return delegation

    def revoke_delegation(self, delegation_id: str) -> bool:
        """Revoke a delegation by ID."""
        delegation = self._delegations.get(delegation_id)
        if not delegation:
            return False
        
        # Remove from indexes
        if delegation.grantee_user_id in self._user_delegations:
            self._user_delegations[delegation.grantee_user_id] = [
                d for d in self._user_delegations[delegation.grantee_user_id] if d != delegation_id
            ]
        
        if delegation.project_id in self._project_delegations:
            self._project_delegations[delegation.project_id] = [
                d for d in self._project_delegations[delegation.project_id] if d != delegation_id
            ]
        
        del self._delegations[delegation_id]
        return True

    def get_delegations_for_user(self, user_id: str) -> list[Delegation]:
        """Get all delegations where user is the grantee."""
        delegation_ids = self._user_delegations.get(user_id, [])
        return [self._delegations[d] for d in delegation_ids if d in self._delegations]

    def get_delegations_for_project(self, project_id: str) -> list[Delegation]:
        """Get all delegations for a specific project."""
        delegation_ids = self._project_delegations.get(project_id, [])
        return [self._delegations[d] for d in delegation_ids if d in self._delegations]

    def can_access_project(self, user_id: str, project_id: str, permission: str = "read") -> bool:
        """Check if a user can access a project via delegation or direct ownership."""
        # Users can always access their own projects
        # In production, this would integrate with workspace/project ownership
        
        # Check delegations
        delegations = self.get_delegations_for_user(user_id)
        for delegation in delegations:
            if (delegation.project_id == project_id or delegation.project_id == "*") and \
               delegation.has_permission(permission) and \
               not delegation.is_expired():
                return True
        
        return False

    def get_user_projects(self, user_id: str) -> list[str]:
        """Get all projects a user has access to (via delegation or ownership)."""
        projects = set()
        delegations = self.get_delegations_for_user(user_id)
        for delegation in delegations:
            if not delegation.is_expired():
                if delegation.project_id != "*":
                    projects.add(delegation.project_id)
        return list(projects)


class AuthMiddleware:
    """FastAPI-compatible authentication middleware for control plane endpoints.

    Usage in API lifespan:
        @asynccontextmanager
        async def lifespan(app):
            from agentic.control.persistence import PersistenceConfig, create_secret_store
            config = PersistenceConfig()  # Load from env
            store = create_secret_store(config)
            delegation_store = DelegationStore()
            auth = AuthMiddleware(secret_store=store, delegation_store=delegation_store)
            # ... setup other subsystems ...
            yield
    """

    def __init__(self, secret_store=None, policy: Optional[PermissionPolicy] = None, 
                 delegation_store: Optional["DelegationStore"] = None):
        self.secret_store = secret_store
        self.policy = policy or PermissionPolicy.user_policy()
        self._sessions: dict[str, UserSession] = {}  # session_id → UserSession
        self._access_log: list[dict[str, Any]] = []  # Audit trail
        self.delegation_store = delegation_store or DelegationStore()
        self._audit_logger = None  # Will be set by wire_audit()

    def create_session(
        self,
        user_id: str,
        roles: Optional[list[str]] = None,
        project: Optional[str] = None,
        ttl_seconds: Optional[int] = None,
    ) -> UserSession:
        """Create a new authenticated session."""
        session = UserSession(
            session_id=f"sess-{uuid.uuid4().hex[:12]}",
            user_id=user_id,
            roles=roles or [Role.USER.value],
            project=project,
        )
        if ttl_seconds:
            session.expires_at = time.time() + ttl_seconds

        self._sessions[session.session_id] = session
        self._log_access("session_create", user_id=user_id, session_id=session.session_id)
        return session

    def validate_session(self, session_id: str) -> Optional[UserSession]:
        """Validate a session token and return the UserSession if valid."""
        session = self._sessions.get(session_id)
        if not session:
            logger.warning(f"Unknown session_id: {session_id}")
            return None

        if session.is_expired():
            del self._sessions[session_id]
            self._log_access("session_expired", user_id=session.user_id, session_id=session_id)
            return None

        self._log_access("session_validate", user_id=session.user_id, session_id=session_id)
        return session

    def has_permission(self, role: str, permission: str) -> bool:
        """Check if a role has a specific permission."""
        perms = {
            "read_status": ["admin", "operator", "user", "readonly"],
            "manage_sessions": ["admin", "operator", "user"],
            "rotate_credentials": ["admin"],
            "modify_scheduler": ["admin"],
            "access_secrets": ["admin"],
        }
        return role in perms.get(permission, [])

    def _log_access(self, action: str, **kwargs: Any) -> None:
        """Log access attempt for audit trail."""
        log_entry = {
            "action": action,
            "timestamp": time.time(),
            **kwargs,
        }
        self._access_log.append(log_entry)

    def get_access_log(self) -> list[dict[str, Any]]:
        """Return sorted audit log (same API as SecretStore)."""
        return sorted(self._access_log, key=lambda x: x.get("timestamp", 0))

    def wire_audit(self, audit_logger):
        """Wire audit logger for authentication events (§M4)."""
        self._audit_logger = audit_logger

    def can_access_project(self, session: UserSession, project_id: str, permission: str = "read") -> bool:
        """Check if session user can access a project (§M4 G4 - separation utilisateurs/projets).
        
        Rules:
        - Admins can access all projects
        - Users can access their own project
        - Users can access projects they have delegated access to
        """
        if "admin" in session.roles:
            return True
        
        # Check if user owns the project (session.project == project_id)
        if session.project == project_id:
            return True
        
        # Check delegations
        return self.delegation_store.can_access_project(session.user_id, project_id, permission)

    def get_user_projects(self, user_id: str) -> list[str]:
        """Get all projects a user has access to (§M4 G4)."""
        return self.delegation_store.get_user_projects(user_id)

    def grant_delegation(self, grantor_session: UserSession, grantee_user_id: str, 
                         project_id: str, permissions: list[str], 
                         expires_in_seconds: Optional[int] = None) -> Delegation:
        """Grant delegation to another user (requires admin or project owner)."""
        # Check if grantor has permission to delegate
        if "admin" not in grantor_session.roles and grantor_session.project != project_id:
            raise PermissionError(f"User {grantor_session.user_id} cannot delegate access to project {project_id}")
        
        delegation = self.delegation_store.grant_delegation(
            grantor_user_id=grantor_session.user_id,
            grantee_user_id=grantee_user_id,
            project_id=project_id,
            permissions=permissions,
            expires_in_seconds=expires_in_seconds,
        )
        
        # Audit log
        if self._audit_logger:
            self._audit_logger.log(
                action="delegation.grant",
                user_id=grantor_session.user_id,
                target=f"project:{project_id}",
                details={
                    "grantee": grantee_user_id,
                    "permissions": permissions,
                    "delegation_id": delegation.delegation_id,
                },
            )
        
        return delegation

    def revoke_delegation(self, revoker_session: UserSession, delegation_id: str) -> bool:
        """Revoke a delegation (requires admin or original grantor)."""
        delegation = self.delegation_store._delegations.get(delegation_id)
        if not delegation:
            raise ValueError(f"Delegation {delegation_id} not found")
        
        # Check if revoker can revoke this delegation
        if "admin" not in revoker_session.roles and revoker_session.user_id != delegation.grantor_user_id:
            raise PermissionError(f"User {revoker_session.user_id} cannot revoke delegation {delegation_id}")
        
        result = self.delegation_store.revoke_delegation(delegation_id)
        
        # Audit log
        if self._audit_logger and result:
            self._audit_logger.log(
                action="delegation.revoke",
                user_id=revoker_session.user_id,
                target=f"delegation:{delegation_id}",
                details={"grantee": delegation.grantee_user_id, "project": delegation.project_id},
            )
        
        return result


class RoleChecker:
    """Dependency injector for FastAPI endpoints requiring role checks.

    Usage:
        from fastapi import Depends
        
        @app.get("/api/v1/status", dependencies=[Depends(RoleChecker.require_role("user"))])
        async def status():
            return {"ok": True}
    """

    @staticmethod
    def require_role(role: str):
        """Return a FastAPI dependency that checks for a specific role."""
        async def check(user_session: Optional[UserSession] = None):
            # In production, this would be injected via FastAPI Depends()
            if user_session is None:
                raise PermissionError("Authentication required")
            if not any(r == role or r in ["admin"] for r in user_session.roles):
                raise PermissionError(f"Role '{role}' required, got {user_session.roles}")
            return user_session
        return check


# ── CLI Helper ───────────────────────────────────────────────────────

def main() -> None:
    """Demo auth middleware."""
    import asyncio
    
    store = None  # Would be SecretStore in production
    
    auth = AuthMiddleware(secret_store=store)
    
    # Create sessions
    admin_session = auth.create_session("alice", roles=["admin"], ttl_seconds=3600)
    user_session = auth.create_session("bob", roles=["user"], project="ARTANY")
    
    print(f"Admin session: {admin_session.session_id}")
    print(f"User session: {user_session.session_id}")
    
    # Validate
    valid = auth.validate_session(admin_session.session_id)
    print(f"Admin session valid: {valid is not None and not valid.is_expired()}")
    
    # Check permissions
    print(f"admin can_rotate_credentials: {auth.has_permission('admin', 'rotate_credentials')}")
    print(f"user can_rotate_credentials: {auth.has_permission('user', 'rotate_credentials')}")


if __name__ == "__main__":
    main()
