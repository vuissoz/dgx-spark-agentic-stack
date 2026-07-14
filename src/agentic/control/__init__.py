"""Control plane module (§3.1, §5, §11).

Components:
- api.py            : FastAPI control plane with REST/SSE endpoints
- scheduler.py      : Resource admission and work scheduling (§11)
- reconciler.py     : Desired/observed state reconciliation (§3.1)
- worker.py         : Background task execution with outbox pattern (§3.1)
- postgres_schema.py: PostgreSQL schema definitions for control data (§4)
- persistence.py    : MemoryOutbox/PgOutbox factory + SecretStore backends (§4)
- architecture_validator.py : Architectural constraint validator (§3.4)

Usage:
    from agentic.control.api import control_api, initialize_control_plane
    
    initialize_control_plane()
    control_api.start(host="127.0.0.1", port=8080)
"""

from .api import control_api, initialize_control_plane, get_control_state
from .scheduler import Scheduler, SchedulerState, ResourceLimits, AdmissionResult, QueueMode
from .reconciler import StateReconciler, OutboxReconciler, DriftReport
from .worker import TaskWorker, WorkerContext, TaskOutbox

__all__ = [
    "control_api",
    "initialize_control_plane",
    "get_control_state",
    "Scheduler",
    "SchedulerState",
    "ResourceLimits",
    "AdmissionResult",
    "QueueMode",
    "StateReconciler",
    "OutboxReconciler",
    "DriftReport",
    "TaskWorker",
    "WorkerContext",
    "TaskOutbox",
]
