#!/usr/bin/env python3
"""src/agentic/control/persistence.py — PostgreSQL and in-memory persistence backends (§4).

Provides abstract persistence interfaces with two tiers:
- In-memory fallback (default, rootless-dev friendly)
- PostgreSQL backend (when DB connectivity is available)
- Optional Fernet encryption layer for sensitive data

Conforms to PLAN.md §4 (sources de vérité) and §10.1 (secrets management).

Usage:
    from agentic.control.persistence import (
        PersistenceConfig, MemoryOutbox, PgOutbox,
        create_outbox, create_secret_store
    )
    
    config = PersistenceConfig(pg_host="pg", pg_password="secret")
    outbox = create_outbox(config)  # PgOutbox when PG available
    store = create_secret_store(config)  # Encrypted secret store
"""

from __future__ import annotations

import hashlib
import logging
import time
import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, Optional

logger = logging.getLogger(__name__)


@dataclass
class PersistenceConfig:
    """Configuration for persistence backends."""
    pg_host: str = ""
    pg_port: int = 5432
    pg_database: str = "agentic_control"
    pg_user: str = ""
    pg_password: str = ""
    encryption_key: Optional[str] = None  # Fernet base64-encoded key
    
    @property
    def has_pg(self) -> bool:
        return bool(self.pg_host and self.pg_password)
    
    @property
    def has_encryption(self) -> bool:
        return bool(self.encryption_key)


# ── Abstract Persistence Interfaces ───────────────────────────────────

class OutboxBackend(ABC):
    """Abstract outbox backend for durable task results."""
    
    @abstractmethod
    async def push(self, task_id: str, status: str, result: dict[str, Any] | None = None,
                   correlation_id: Optional[str] = None) -> str: ...
    
    @abstractmethod
    async def pull_completed(self) -> list[dict[str, Any]]: ...
    
    @abstractmethod
    async def clear_processed(self, correlation_ids: set[str]) -> None: ...


class SecretStoreBackend(ABC):
    """Abstract secret store backend with encryption at rest."""
    
    @abstractmethod
    async def store(self, name: str, value: str, scope: str = "*") -> None: ...
    
    @abstractmethod
    async def get_hash(self, name: str) -> Optional[str]: ...
    
    @abstractmethod
    async def exists(self, name: str) -> bool: ...
    
    @abstractmethod
    async def rotate(self, name: str, new_value: str) -> None: ...


# ── In-Memory Implementations ────────────────────────────────────────

class MemoryOutbox(OutboxBackend):
    """In-memory outbox (fallback backend, rootless-dev default)."""
    
    def __init__(self):
        self._entries: list[dict[str, Any]] = []
    
    async def push(self, task_id: str, status: str, result: dict[str, Any] | None = None,
                   correlation_id: Optional[str] = None) -> str:
        cid = correlation_id or uuid.uuid4().hex[:12]
        entry = {
            "task_id": task_id,
            "correlation_id": cid,
            "status": status,
            "result": result or {},
            "submitted_at": time.time(),
        }
        self._entries.append(entry)
        return cid
    
    async def pull_completed(self) -> list[dict[str, Any]]:
        return [e for e in self._entries if e["status"] in ("completed", "failed")]
    
    async def clear_processed(self, correlation_ids: set[str]) -> None:
        self._entries = [e for e in self._entries if e.get("correlation_id") not in correlation_ids]


class MemorySecretStore(SecretStoreBackend):
    """In-memory secret store with SHA-256 hashing (fallback backend)."""
    
    def __init__(self, encryption_key: Optional[str] = None):
        self._secrets: dict[str, dict[str, Any]] = {}
        self._encryption_key = encryption_key
    
    def _encrypt_value(self, value: str) -> str:
        if self._encryption_key:
            try:
                from cryptography.fernet import Fernet
                key = self._encryption_key.encode() if isinstance(self._encryption_key, str) else self._encryption_key
                f = Fernet(key)
                return f.encrypt(value.encode()).decode()
            except ImportError:
                logger.warning("cryptography module not available, using hash-only storage")
            except Exception as e:
                logger.error(f"Encryption failed, falling back to hash: {e}")
        return hashlib.sha256(value.encode()).hexdigest()
    
    async def store(self, name: str, value: str, scope: str = "*") -> None:
        self._secrets[name] = {
            "value": self._encrypt_value(value),
            "scope": scope,
            "created_at": time.time(),
            "rotated": False,
        }
    
    async def get_hash(self, name: str) -> Optional[str]:
        secret = self._secrets.get(name)
        if not secret:
            return None
        val = secret["value"]
        if isinstance(val, str):
            return hashlib.sha256(val.encode()).hexdigest()[:16]
        return val[:32]
    
    async def exists(self, name: str) -> bool:
        return name in self._secrets
    
    async def rotate(self, name: str, new_value: str) -> None:
        if name not in self._secrets:
            raise ValueError(f"Secret '{name}' does not exist for rotation")
        secret = self._secrets[name]
        if "history" not in secret:
            secret["history"] = []
        secret["history"].append({
            "old_hash": secret["value"][:32],
            "rotated_at": time.time(),
        })
        secret["value"] = self._encrypt_value(new_value)
        secret["rotated"] = True


# ── PostgreSQL Implementations (Optional, asyncpg required) ────────────

class PgOutbox(OutboxBackend):
    """PostgreSQL-backed outbox for durable task results."""
    
    def __init__(self, config: PersistenceConfig):
        self._config = config
        self._conn = None
    
    async def _ensure_connection(self):
        try:
            import asyncpg
        except ImportError:
            raise RuntimeError("asyncpg required for PostgreSQL outbox. pip install asyncpg")
        
        if self._conn is None or self._conn.is_closed():
            dsn = (
                f"postgresql://{self._config.pg_user}:{self._config.pg_password}"
                f"@{self._config.pg_host}:{self._config.pg_port}/{self._config.pg_database}"
            )
            self._conn = await asyncpg.connect(dsn)
            await self._conn.execute("""
                CREATE TABLE IF NOT EXISTS agentic_control.outbox (
                    task_id TEXT, correlation_id TEXT, status TEXT CHECK (status IN ('pending','running','completed','failed')),
                    result JSONB DEFAULT '{}', submitted_at TIMESTAMPTZ DEFAULT now()
                )
            """)
    
    async def push(self, task_id, status, result=None, correlation_id=None):
        await self._ensure_connection()
        cid = correlation_id or uuid.uuid4().hex[:12]
        await self._conn.execute(
            "INSERT INTO agentic_control.outbox (task_id,correlation_id,status,result) VALUES ($1,$2,$3,$4)",
            task_id, cid, status, result or {}
        )
        return cid
    
    async def pull_completed(self):
        await self._ensure_connection()
        rows = await self._conn.fetch(
            "SELECT * FROM agentic_control.outbox WHERE status IN ('completed','failed') ORDER BY submitted_at"
        )
        return [dict(r) for r in rows]
    
    async def clear_processed(self, correlation_ids):
        if not correlation_ids:
            return
        await self._ensure_connection()
        await self._conn.execute(
            "DELETE FROM agentic_control.outbox WHERE correlation_id = ANY($1)", list(correlation_ids)
        )


class PgSecretStore(SecretStoreBackend):
    """PostgreSQL-backed secret store with Fernet encryption."""
    
    def __init__(self, config: PersistenceConfig):
        self._config = config
    
    async def _get_fernet(self):
        if not self._config.has_encryption:
            raise RuntimeError("encryption_key required for PgSecretStore")
        try:
            from cryptography.fernet import Fernet
        except ImportError:
            raise RuntimeError("cryptography required. pip install cryptography")
        key = self._config.encryption_key.encode() if isinstance(self._config.encryption_key, str) else self._config.encryption_key
        return Fernet(key)
    
    async def _ensure_connection(self):
        try:
            import asyncpg
        except ImportError:
            raise RuntimeError("asyncpg required. pip install asyncpg")
        
        if not hasattr(self, '_conn') or self._conn is None or self._conn.is_closed():
            dsn = (
                f"postgresql://{self._config.pg_user}:{self._config.pg_password}"
                f"@{self._config.pg_host}:{self._config.pg_port}/{self._config.pg_database}"
            )
            self._conn = await asyncpg.connect(dsn)
            await self._conn.execute("""
                CREATE TABLE IF NOT EXISTS agentic_control.secrets (
                    name TEXT PRIMARY KEY, encrypted_value BYTEA NOT NULL,
                    scope TEXT DEFAULT '*', created_at TIMESTAMPTZ DEFAULT now(),
                    rotated_at TIMESTAMPTZ, rotation_count INT DEFAULT 0
                )
            """)
    
    async def store(self, name: str, value: str, scope: str = "*") -> None:
        fernet = await self._get_fernet()
        encrypted = fernet.encrypt(value.encode())
        await self._ensure_connection()
        await self._conn.execute(
            """INSERT INTO agentic_control.secrets (name, encrypted_value, scope) VALUES ($1,$2,$3)
               ON CONFLICT (name) DO UPDATE SET encrypted_value=EXCLUDED.encrypted_value, scope=EXCLUDED.scope""",
            name, encrypted, scope
        )
    
    async def get_hash(self, name: str) -> Optional[str]:
        await self._ensure_connection()
        row = await self._conn.fetchrow("SELECT encrypted_value FROM agentic_control.secrets WHERE name=$1", name)
        return hashlib.sha256(row["encrypted_value"]).hexdigest()[:16] if row else None
    
    async def exists(self, name: str) -> bool:
        await self._ensure_connection()
        return await self._conn.fetchval("SELECT 1 FROM agentic_control.secrets WHERE name=$1", name) is not None
    
    async def rotate(self, name: str, new_value: str) -> None:
        if not await self.exists(name):
            raise ValueError(f"Secret '{name}' does not exist")
        fernet = await self._get_fernet()
        encrypted = fernet.encrypt(new_value.encode())
        await self._ensure_connection()
        await self._conn.execute(
            "UPDATE agentic_control.secrets SET encrypted_value=$1, rotated_at=now(), rotation_count=rotation_count+1 WHERE name=$2",
            encrypted, name
        )


# ── Factory Functions ─────────────────────────────────────────────────

def create_outbox(config: PersistenceConfig) -> OutboxBackend:
    """Factory: returns PgOutbox when PG configured, MemoryOutbox otherwise."""
    if config.has_pg:
        logger.info("Creating PostgreSQL outbox backend")
        return PgOutbox(config)
    logger.debug("Using in-memory outbox (PostgreSQL not configured)")
    return MemoryOutbox()


def create_secret_store(config: PersistenceConfig) -> SecretStoreBackend:
    """Factory: returns encrypted PgSecretStore, or fallback store."""
    if config.has_pg and config.has_encryption:
        logger.info("Creating PostgreSQL encrypted secret store")
        return PgSecretStore(config)
    elif config.has_pg:
        logger.warning("PostgreSQL configured but no encryption key - using hash-only fallback")
        return MemorySecretStore()
    logger.debug("Using in-memory secret store (fallback)")
    return MemorySecretStore(config.encryption_key)


# ── CLI Helper ───────────────────────────────────────────────────────

def main() -> None:
    """Demo persistence backends."""
    import asyncio
    
    # Demo in-memory outbox
    outbox = create_outbox(PersistenceConfig())
    asyncio.run(outbox.push("task-1", "running"))
    asyncio.run(outbox.push("task-1", "completed", {"result": "done"}))
    completed = asyncio.run(outbox.pull_completed())
    print(f"In-memory outbox: {len(completed)} completed entries")
    
    # Demo in-memory secret store
    store = create_secret_store(PersistenceConfig())
    asyncio.run(store.store("github_token", "ghp_xxxxxxxxxxxx"))
    exists = asyncio.run(store.exists("github_token"))
    print(f"In-memory SecretStore: github_token exists={exists}")


if __name__ == "__main__":
    main()
