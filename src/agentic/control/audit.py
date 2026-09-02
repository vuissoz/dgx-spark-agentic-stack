#!/usr/bin/env python3
"""src/agentic/control/audit.py — Complete audit trail for control plane (§M4).

Provides:
- Structured audit logging for all control plane actions
- Correlation with SecretStore access logs
- Integration with PostgreSQL audit_log table
- Audit context propagation via async context vars

Conforms to PLAN.md §M4 (Fondation production) and §4 (audit corrélé complet).

Usage:
    from agentic.control.audit import AuditLogger, audit_context
    
    # Initialize with optional PostgreSQL backend
    audit = AuditLogger(pg_connection_string=os.environ.get("DATABASE_URL"))
    
    # In FastAPI endpoint or service:
    async with audit_context(user_id="alice", action="start_session", run_id="run-123"):
        # ... perform action ...
        audit.log_success(result={"session_id": "sess-abc"})
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
import uuid
from contextvars import ContextVar
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Optional

logger = logging.getLogger(__name__)


class AuditAction(Enum):
    """Control plane action categories for audit classification."""
    AUTH_LOGIN = "auth.login"
    AUTH_LOGOUT = "auth.logout"
    AUTH_VALIDATE = "auth.validate"
    SESSION_START = "session.start"
    SESSION_END = "session.end"
    SESSION_LIST = "session.list"
    WORKSPACE_CREATE = "workspace.create"
    WORKSPACE_SWITCH = "workspace.switch"
    WORKSPACE_DELETE = "workspace.delete"
    SCHEDULER_ADMIT = "scheduler.admit"
    SCHEDULER_REJECT = "scheduler.reject"
    CONFIG_READ = "config.read"
    CONFIG_WRITE = "config.write"
    SECRET_ACCESS = "secret.access"
    SECRET_ROTATE = "secret.rotate"
    RECONCILER_RUN = "reconciler.run"
    RECONCILER_DRIFT = "reconciler.drift"
    BACKUP_CREATE = "backup.create"
    BACKUP_RESTORE = "backup.restore"
    UPGRADE_START = "upgrade.start"
    UPGRADE_ROLLBACK = "upgrade.rollback"


class AuditStatus(Enum):
    """Audit entry status."""
    STARTED = "started"
    SUCCESS = "success"
    FAILED = "failed"
    ROLLED_BACK = "rolled_back"


@dataclass
class AuditEntry:
    """Structured audit log entry."""
    entry_id: str = field(default_factory=lambda: f"audit-{uuid.uuid4().hex[:12]}")
    timestamp: float = field(default_factory=time.time)
    action: str = ""
    status: str = AuditStatus.STARTED.value
    user_id: str = ""
    roles: list[str] = field(default_factory=list)
    project_id: Optional[str] = None
    run_id: Optional[str] = None
    session_id: Optional[str] = None
    target: str = ""  # e.g., "scheduler", "workspace:myproject", "secret:github_token"
    details: dict[str, Any] = field(default_factory=dict)
    error: Optional[str] = None
    correlation_id: Optional[str] = None  # For tracing across services
    ip_address: Optional[str] = None
    user_agent: Optional[str] = None

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "entry_id": self.entry_id,
            "timestamp": self.timestamp,
            "action": self.action,
            "status": self.status,
            "user_id": self.user_id,
            "roles": self.roles,
            "project_id": self.project_id,
            "run_id": self.run_id,
            "session_id": self.session_id,
            "target": self.target,
            "details": self.details,
            "error": self.error,
            "correlation_id": self.correlation_id,
            "ip_address": self.ip_address,
            "user_agent": self.user_agent,
        }

    def to_json(self) -> str:
        """Convert to JSON string."""
        return json.dumps(self.to_dict(), default=str, sort_keys=True)


# Context variable for audit context propagation
_audit_context: ContextVar[dict[str, Any]] = ContextVar("audit_context", default={})


def audit_context(
    user_id: Optional[str] = None,
    roles: Optional[list[str]] = None,
    project_id: Optional[str] = None,
    run_id: Optional[str] = None,
    session_id: Optional[str] = None,
    correlation_id: Optional[str] = None,
    action: Optional[str] = None,
    target: Optional[str] = None,
) -> Any:
    """Async context manager for audit context propagation.
    
    Usage:
        async with audit_context(user_id="alice", action="start_session", run_id="run-123"):
            # All audit log entries within this context will include these values
            audit.log("session_start", details={"model": "claude-3"})
    """
    class AuditContextManager:
        def __init__(self, context: dict[str, Any]):
            self.context = context
            self._token = None

        async def __aenter__(self):
            self._token = _audit_context.set(self.context)
            return self

        async def __aexit__(self, exc_type, exc_val, exc_tb):
            _audit_context.reset(self._token)
            return False

    context = {
        "user_id": user_id,
        "roles": roles or [],
        "project_id": project_id,
        "run_id": run_id,
        "session_id": session_id,
        "correlation_id": correlation_id,
        "action": action,
        "target": target,
        "start_time": time.time(),
    }
    return AuditContextManager(context)


def get_audit_context() -> dict[str, Any]:
    """Get the current audit context."""
    return _audit_context.get().copy()


class AuditLogger:
    """Centralized audit logging for control plane actions (§M4).
    
    Features:
    - In-memory audit log (for testing and fallback)
    - PostgreSQL audit log table persistence
    - Structured JSON logging to stdout/file
    - Correlation with SecretStore access logs
    - Context propagation via async context vars
    """

    def __init__(
        self,
        pg_connection_string: Optional[str] = None,
        log_file: Optional[str] = None,
        secret_store: Optional[Any] = None,
    ):
        self.pg_connection_string = pg_connection_string or os.environ.get("DATABASE_URL")
        self.log_file = log_file or os.environ.get("AUDIT_LOG_FILE", "/var/log/agentic/audit.log")
        self.secret_store = secret_store
        
        self._in_memory_log: list[AuditEntry] = []
        self._max_in_memory_entries = 10000
        
        # Ensure log directory exists
        if self.log_file:
            log_dir = os.path.dirname(self.log_file)
            if log_dir:
                os.makedirs(log_dir, exist_ok=True)

    def _get_base_entry(self, action: str, status: AuditStatus = AuditStatus.STARTED) -> AuditEntry:
        """Create base audit entry from current context."""
        context = get_audit_context()
        
        entry = AuditEntry(
            action=action,
            status=status.value,
            user_id=context.get("user_id", ""),
            roles=context.get("roles", []),
            project_id=context.get("project_id"),
            run_id=context.get("run_id"),
            session_id=context.get("session_id"),
            correlation_id=context.get("correlation_id"),
            target=context.get("target", ""),
        )
        
        # Add IP and user agent from environment if available
        entry.ip_address = os.environ.get("REMOTE_ADDR") or context.get("ip_address")
        entry.user_agent = os.environ.get("HTTP_USER_AGENT") or context.get("user_agent")
        
        return entry

    def log(
        self,
        action: str,
        status: AuditStatus = AuditStatus.STARTED,
        target: Optional[str] = None,
        details: Optional[dict[str, Any]] = None,
        error: Optional[str] = None,
    ) -> AuditEntry:
        """Log an audit entry."""
        entry = self._get_base_entry(action, status)
        
        if target:
            entry.target = target
        if details:
            entry.details = details
        if error:
            entry.error = error
        
        # Add to in-memory log
        self._add_to_memory(entry)
        
        # Write to file
        self._write_to_file(entry)
        
        # Write to PostgreSQL if configured
        if self.pg_connection_string:
            self._write_to_postgres(entry)
        
        # Log to SecretStore if configured
        if self.secret_store and hasattr(self.secret_store, "audit_log"):
            self._write_to_secret_store(entry)
        
        return entry

    def log_start(
        self,
        action: str,
        target: Optional[str] = None,
        details: Optional[dict[str, Any]] = None,
    ) -> AuditEntry:
        """Log the start of an action."""
        return self.log(action, AuditStatus.STARTED, target, details)

    def log_success(
        self,
        action: str,
        target: Optional[str] = None,
        details: Optional[dict[str, Any]] = None,
    ) -> AuditEntry:
        """Log the successful completion of an action."""
        return self.log(action, AuditStatus.SUCCESS, target, details)

    def log_failure(
        self,
        action: str,
        error: str,
        target: Optional[str] = None,
        details: Optional[dict[str, Any]] = None,
    ) -> AuditEntry:
        """Log a failed action."""
        return self.log(action, AuditStatus.FAILED, target, details, error)

    def log_rollback(
        self,
        action: str,
        target: Optional[str] = None,
        details: Optional[dict[str, Any]] = None,
    ) -> AuditEntry:
        """Log a rollback action."""
        return self.log(action, AuditStatus.ROLLED_BACK, target, details)

    def _add_to_memory(self, entry: AuditEntry) -> None:
        """Add entry to in-memory log with rotation."""
        self._in_memory_log.append(entry)
        
        # Rotate if too many entries
        if len(self._in_memory_log) > self._max_in_memory_entries:
            self._in_memory_log = self._in_memory_log[-self._max_in_memory_entries // 2 :]

    def _write_to_file(self, entry: AuditEntry) -> None:
        """Write entry to log file."""
        if not self.log_file:
            return
            
        try:
            with open(self.log_file, "a", encoding="utf-8") as f:
                f.write(entry.to_json() + "\n")
        except Exception as e:
            logger.warning(f"Failed to write audit entry to file: {e}")

    def _write_to_postgres(self, entry: AuditEntry) -> None:
        """Write entry to PostgreSQL audit_log table."""
        # Import here to avoid circular dependencies
        try:
            import asyncpg
            import asyncio
        except ImportError:
            logger.debug("asyncpg not available, skipping PostgreSQL audit logging")
            return
        
        async def _async_write():
            try:
                conn = await asyncpg.connect(self.pg_connection_string)
                await conn.execute("""
                    INSERT INTO agentic_control.audit_log (
                        entry_id, timestamp, action, status, user_id, roles, 
                        project_id, run_id, session_id, target, details, error,
                        correlation_id, ip_address, user_agent
                    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
                """,
                    entry.entry_id,
                    entry.timestamp,
                    entry.action,
                    entry.status,
                    entry.user_id,
                    json.dumps(entry.roles),
                    entry.project_id,
                    entry.run_id,
                    entry.session_id,
                    entry.target,
                    json.dumps(entry.details),
                    entry.error,
                    entry.correlation_id,
                    entry.ip_address,
                    entry.user_agent,
                )
                await conn.close()
            except Exception as e:
                logger.warning(f"Failed to write audit entry to PostgreSQL: {e}")
        
        # Run async write in background
        try:
            asyncio.create_task(_async_write())
        except RuntimeError:
            # No running event loop, log warning
            logger.debug("No async event loop, PostgreSQL audit write deferred")

    def _write_to_secret_store(self, entry: AuditEntry) -> None:
        """Write entry to SecretStore audit log."""
        if not self.secret_store:
            return
        
        try:
            # Convert entry to format expected by SecretStore
            store_entry = {
                "action": entry.action,
                "timestamp": entry.timestamp,
                "user_id": entry.user_id,
                "status": entry.status,
                "target": entry.target,
                "details": entry.details,
                "error": entry.error,
                "entry_id": entry.entry_id,
            }
            self.secret_store.audit_log(entry=store_entry)
        except Exception as e:
            logger.warning(f"Failed to write audit entry to SecretStore: {e}")

    def get_audit_log(
        self,
        limit: Optional[int] = None,
        user_id: Optional[str] = None,
        action: Optional[str] = None,
        since: Optional[float] = None,
    ) -> list[AuditEntry]:
        """Get audit log entries with optional filtering."""
        entries = self._in_memory_log.copy()
        
        # Apply filters
        if user_id:
            entries = [e for e in entries if e.user_id == user_id]
        if action:
            entries = [e for e in entries if e.action == action]
        if since:
            entries = [e for e in entries if e.timestamp >= since]
        
        # Sort by timestamp descending
        entries.sort(key=lambda e: e.timestamp, reverse=True)
        
        if limit:
            entries = entries[:limit]
        
        return entries

    def get_correlated_entries(self, correlation_id: str) -> list[AuditEntry]:
        """Get all audit entries with a specific correlation ID."""
        return [e for e in self._in_memory_log if e.correlation_id == correlation_id]

    def get_user_actions(
        self,
        user_id: str,
        limit: Optional[int] = None,
        since: Optional[float] = None,
    ) -> list[AuditEntry]:
        """Get all actions performed by a specific user."""
        return self.get_audit_log(limit=limit, user_id=user_id, since=since)

    def get_project_actions(
        self,
        project_id: str,
        limit: Optional[int] = None,
        since: Optional[float] = None,
    ) -> list[AuditEntry]:
        """Get all actions related to a specific project."""
        return self.get_audit_log(
            limit=limit,
            user_id=None,
            action=None,
            since=since,
        ) + [e for e in self._in_memory_log if e.project_id == project_id and (since is None or e.timestamp >= since)]

    def clear(self) -> None:
        """Clear in-memory audit log (useful for testing)."""
        self._in_memory_log.clear()


# Global audit logger instance (lazy initialization)
_global_audit: Optional[AuditLogger] = None


def get_audit_logger() -> AuditLogger:
    """Get or create the global audit logger instance."""
    global _global_audit
    if _global_audit is None:
        _global_audit = AuditLogger()
    return _global_audit


def reset_audit_logger() -> None:
    """Reset the global audit logger (useful for testing)."""
    global _global_audit
    if _global_audit is not None:
        _global_audit.clear()
    _global_audit = None


# Convenience functions for direct use
def audit_log(
    action: str,
    status: AuditStatus = AuditStatus.STARTED,
    target: Optional[str] = None,
    details: Optional[dict[str, Any]] = None,
    error: Optional[str] = None,
) -> AuditEntry:
    """Log an audit entry using the global audit logger."""
    return get_audit_logger().log(action, status, target, details, error)


def audit_start(
    action: str,
    target: Optional[str] = None,
    details: Optional[dict[str, Any]] = None,
) -> AuditEntry:
    """Log the start of an action using the global audit logger."""
    return get_audit_logger().log_start(action, target, details)


def audit_success(
    action: str,
    target: Optional[str] = None,
    details: Optional[dict[str, Any]] = None,
) -> AuditEntry:
    """Log the successful completion of an action using the global audit logger."""
    return get_audit_logger().log_success(action, target, details)


def audit_failure(
    action: str,
    error: str,
    target: Optional[str] = None,
    details: Optional[dict[str, Any]] = None,
) -> AuditEntry:
    """Log a failed action using the global audit logger."""
    return get_audit_logger().log_failure(action, error, target, details)


# ── CLI Helper ───────────────────────────────────────────────────────

def main() -> None:
    """Demo audit logging."""
    import asyncio
    
    audit = AuditLogger(log_file="/tmp/audit_demo.log")
    
    # Test in-memory logging
    entry = audit.log_start("session.start", target="workspace:myproject")
    print(f"Logged entry: {entry.entry_id}")
    
    entry = audit.log_success("session.start", target="workspace:myproject", 
                               details={"model": "claude-3", "tokens": 1000})
    print(f"Success entry: {entry.entry_id}")
    
    # Test context propagation
    async def test_context():
        async with audit_context(user_id="alice", roles=["admin"], project_id="ARTANY", 
                                  run_id="run-123", action="upgrade"):
            entry = audit.log("upgrade.start")
            print(f"Context entry user_id: {entry.user_id}, project: {entry.project_id}")
    
        asyncio.run(test_context())
    
    # Show recent entries
    recent = audit.get_audit_log(limit=5)
    print(f"\nRecent audit entries: {len(recent)}")
    for e in recent:
        print(f"  {e.timestamp}: {e.action} ({e.status}) - {e.user_id}")


if __name__ == "__main__":
    main()
