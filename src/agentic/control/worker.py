#!/usr/bin/env python3
"""src/agentic/control/worker.py — Background worker for long tasks (§3.1).

Handles:
- Long-running ingestion, indexing, and benchmark tasks
- PostgreSQL outbox pattern (store results locally, reconcile asynchronously)
- Idempotent execution with correlation identifiers
- Coordination with scheduler admission decisions

This worker runs alongside the API server in the same codebase.
"""

from __future__ import annotations

import asyncio
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Optional


@dataclass
class TaskOutbox:
    """PostgreSQL outbox pattern for durable task results.

    Instead of a distributed bus, tasks write their completion status
    and results to this outbox table/structure. The reconciler reads it
    and updates the desired/observed state accordingly.

    By default uses in-memory persistence (rootless-dev friendly).
    Set persistence_config to enable PostgreSQL-backed persistence.
    """

    entries: list[dict[str, Any]] = field(default_factory=list)  # Legacy attribute
    
    def __init__(self, persistence_config=None):
        """Initialize with optional persistence configuration.

        Args:
            persistence_config: PersistenceConfig instance. If None or no PG configured,
                               uses synchronous in-memory storage (backward compatible).
        """
        self.entries = []  # Re-initialize after dataclass auto-init
        
        if persistence_config is not None and persistence_config.has_pg:
            try:
                from .persistence import create_outbox
                self._pg_backend = create_outbox(persistence_config)
            except ImportError:
                self._pg_backend = None  # asyncpg not available
        else:
            self._pg_backend = None

    # ── Synchronous API (backward compatible) ────────────────────────

    def push(self, task_id, status, result=None, correlation_id=None):
        """Push an outbox entry (synchronous, in-memory)."""
        if self._pg_backend is not None:
            # Delegate to async PG backend synchronously
            try:
                asyncio.get_running_loop()
            except RuntimeError:
                return asyncio.run(self._pg_backend.push(
                    task_id, status, result or {}, correlation_id
                ))
            else:
                raise RuntimeError(
                    "TaskOutbox.push() called from async context with PG backend. "
                    "Use await outbox.push_async() instead."
                )

        entry = {
            "task_id": task_id,
            "correlation_id": correlation_id or uuid.uuid4().hex[:12],
            "status": status,
            "result": result or {},
            "submitted_at": time.time(),
        }
        self.entries.append(entry)
        return entry["correlation_id"]

    def pull_completed(self):
        """Return completed/failed entries for reconciler processing (sync)."""
        if self._pg_backend is not None:
            try:
                asyncio.get_running_loop()
            except RuntimeError:
                return asyncio.run(self._pg_backend.pull_completed())
            else:
                raise RuntimeError(
                    "TaskOutbox.pull_completed() called from async context with PG backend. "
                    "Use await outbox.pull_completed_async() instead."
                )
        return [e for e in self.entries if e["status"] in ("completed", "failed")]

    def clear_processed(self, correlation_ids):
        """Remove processed entries (sync)."""
        if self._pg_backend is not None:
            try:
                asyncio.get_running_loop()
            except RuntimeError:
                return asyncio.run(self._pg_backend.clear_processed(correlation_ids))
            else:
                raise RuntimeError(
                    "TaskOutbox.clear_processed() called from async context with PG backend. "
                    "Use await outbox.clear_processed_async() instead."
                )
        self.entries = [e for e in self.entries if e.get("correlation_id") not in correlation_ids]

    # ── Async API (for PG-backed operations) ─────────────────────────

    async def push_async(self, task_id, status, result=None, correlation_id=None):
        """Async push — requires PostgreSQL backend configured."""
        if self._pg_backend is None:
            raise RuntimeError("PostgreSQL not configured; use TaskOutbox.push() for in-memory")
        return await self._pg_backend.push(task_id, status, result or {}, correlation_id)

    async def pull_completed_async(self):
        """Async pull — requires PostgreSQL backend configured."""
        if self._pg_backend is None:
            raise RuntimeError("PostgreSQL not configured; use TaskOutbox.pull_completed() for in-memory")
        return await self._pg_backend.pull_completed()

    async def clear_processed_async(self, correlation_ids):
        """Async clear — requires PostgreSQL backend configured."""
        if self._pg_backend is None:
            raise RuntimeError("PostgreSQL not configured; use TaskOutbox.clear_processed() for in-memory")
        return await self._pg_backend.clear_processed(correlation_ids)


@dataclass
class WorkerContext:
    """Worker execution context with correlation tracking."""
    task_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    correlation_id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    parent_run_id: Optional[str] = None
    is_idempotent: bool = True
    max_retries: int = 3

    def validate_idempotence(self, executed_task_ids: set[str]) -> bool:
        """Check if this task has already been executed."""
        if not self.is_idempotent:
            return True
        return self.task_id not in executed_task_ids


class TaskWorker:
    """Background worker for long-running tasks.

    Coordinates with the scheduler for admission and uses the outbox
    pattern for durable result delivery to the control plane reconciler.
    """

    def __init__(self, persistence_config=None) -> None:
        self.outbox = TaskOutbox(persistence_config=persistence_config)
        self.running_tasks: dict[str, asyncio.Task] = {}
        self.executed_task_ids: set[str] = set()

    async def execute(self, task_fn: Callable[..., Any], ctx: WorkerContext):
        """Execute a background task with idempotence and outbox delivery."""
        if not ctx.validate_idempotence(self.executed_task_ids):
            return {"status": "skipped", "reason": "task already executed (idempotent)"}

        correlation_id = self.outbox.push(ctx.task_id, "running", correlation_id=ctx.correlation_id)
        try:
            result = task_fn() if callable(task_fn) else {}
            self.outbox.push(
                ctx.task_id, "completed", result={"data": str(result)[:1000]},
                correlation_id=correlation_id,
            )
            self.executed_task_ids.add(ctx.task_id)
            return {"status": "completed", "task_id": ctx.task_id}
        except Exception as exc:
            self.outbox.push(
                ctx.task_id, "failed", result={"error": str(exc)},
                correlation_id=correlation_id,
            )
            return {"status": "failed", "task_id": ctx.task_id, "error": str(exc)}

    def reconcile(self):
        """Pull completed entries for state reconciliation."""
        completed = self.outbox.pull_completed()
        corr_ids = {e["correlation_id"] for e in completed}
        self.outbox.clear_processed(corr_ids)
        return completed

    def list_active(self):
        return list(self.running_tasks.keys())


# ── CLI Demo ─────────────────────────────────────────────────────────

def main() -> None:
    """Demo the worker with in-memory outbox."""
    from .persistence import MemoryOutbox

    outbox = MemoryOutbox()
    asyncio.run(outbox.push("task-1", "running"))
    asyncio.run(outbox.push("task-1", "completed", {"result": "done"}))
    completed = asyncio.run(outbox.pull_completed())
    print(f"Completed entries: {len(completed)}")


if __name__ == "__main__":
    main()
