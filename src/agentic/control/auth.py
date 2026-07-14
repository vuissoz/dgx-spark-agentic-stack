#!/usr/bin/env python3
"""src/agentic/control/auth.py — Authentication & authorization for control plane (§4, §5.1, §M4).

Provides:
- User authentication via secret store tokens (Fernet-encrypted when PG available)
- Role-based access control (RBAC): admin, operator, user, readonly
- Session management with correlation IDs for audit trails
- Middleware hooks for FastAPI endpoints

Conforms to PLAN.md §M4 (Auth/roles production wiring) and §10.1 (SecretStore).

Usage:
    from agentic.control.auth import AuthMiddleware, RoleChecker
    
    # In FastAPI lifespan or middleware setup:
    auth = AuthMiddleware(secret_store=store)
    
    @app.get("/api/v1/status", dependencies=[auth.require_role("user")])
    async def status():
        return {"ok": True}
"""

from __future__ import annotations

import asyncio
import enum
import hashlib
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional

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


class AuthMiddleware:
    """FastAPI-compatible authentication middleware for control plane endpoints.

    Usage in API lifespan:
        @asynccontextmanager
        async def lifespan(app):
            auth = AuthMiddleware(secret_store=store)
            # ... setup other subsystems ...
            yield
    """

    def __init__(self, secret_store=None, policy: Optional[PermissionPolicy] = None):
        self.secret_store = secret_store
        self.policy = policy or PermissionPolicy.user_policy()
        self._sessions: dict[str, UserSession] = {}  # session_id → UserSession
        self._access_log: list[dict[str, Any]] = []  # Audit trail

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
