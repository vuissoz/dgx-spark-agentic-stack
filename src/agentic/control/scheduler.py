#!/usr/bin/env python3
"""src/agentic/control/scheduler.py — Scheduler skeleton with admission and resource management (§11).

Implements:
- Admission for CPU, memory unified, GPU, storage, network
- Queues with priorities and quotas
- Modes: normal, burst, exclusive
- Reservations and calendar (§M10)
- Drain and grace period handling
- Parent/child aggregation for multi-agent trees
- Interactive vs background separation
- File-based persistence for scheduler state (§M10)
- Anti-loop cycle detection and orphan draining

This is the control-plane skeleton. Actual limits are enforced by Docker/Compose
resource constraints; this component tracks state, aggregates budgets, and
provides admission decisions to upstream adapters.
"""

from __future__ import annotations

import enum
import json
import os
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Optional


class QueueMode(enum.Enum):
    NORMAL = "normal"
    BURST = "burst"
    EXCLUSIVE = "exclusive"


class SchedulerEvent(enum.Enum):
    """Events emitted by the scheduler for calendar/preemption."""
    WORKLOAD_ADMITTED = "workload_admitted"
    WORKLOAD_DEQUEUED = "workload_dequeued"
    WORKLOAD_PREEMPTED = "workload_preempted"
    WORKLOAD_RELEASED = "workload_released"
    RESERVATION_CREATED = "reservation_created"
    RESERVATION_FULFILLED = "reservation_fulfilled"
    RESERVATION_EXPIRED = "reservation_expired"
    CALENDAR_TRIGGERED = "calendar_triggered"


@dataclass(frozen=True)
class ResourceLimits:
    """Unified resource envelope for admission."""
    cpus: float = 0.0
    memory_mb: int = 0
    gpu_count: int = 0
    storage_gb: int = 0
    network_bandwidth_mbps: int = 0


@dataclass(frozen=True)
class AdmissionResult:
    granted: bool
    reason: str = ""
    allocated: dict[str, Any] = field(default_factory=dict)


@dataclass
class SchedulerEventRecord:
    """A scheduler event for calendar triggers and audit."""
    event_type: SchedulerEvent
    workload_id: str = ""
    timestamp: float = 0.0
    details: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self):
        if self.timestamp == 0.0:
            object.__setattr__(self, "timestamp", time.time())


@dataclass
class Reservation:
    """A reservation for future resource allocation (§M10)."""
    reservation_id: str = ""
    workload_id: str = ""
    user_id: str = ""
    start_time: float = 0.0
    end_time: float = 0.0
    required_cpu: float = 0.0
    required_memory_mb: int = 0
    required_gpu: int = 0
    priority: int = 50
    fulfilled: bool = False
    cancelled: bool = False

    def __post_init__(self):
        if not self.reservation_id:
            object.__setattr__(self, "reservation_id", f"res-{uuid.uuid4().hex[:8]}")


@dataclass
class CalendarEntry:
    """A scheduled workload entry for calendar-based scheduling (§M10)."""
    entry_id: str = ""
    workload_id: str = ""
    user_id: str = ""
    scheduled_start: float = 0.0
    scheduled_end: float = 0.0
    resource_limits: dict[str, Any] = field(default_factory=dict)
    triggered: bool = False
    priority: int = 50

    def __post_init__(self):
        if not self.entry_id:
            object.__setattr__(self, "entry_id", f"cal-{uuid.uuid4().hex[:8]}")


@dataclass
class SchedulerState:
    """Tracks active workloads, reservations, calendar entries, and system capacity."""
    total_cpu: float = 0.0
    total_memory_mb: int = 0
    total_gpu: int = 0
    total_storage_gb: int = 0

    allocated_cpu: float = 0.0
    allocated_memory_mb: int = 0
    allocated_gpu: int = 0
    allocated_storage_gb: int = 0

    active_workloads: dict[str, dict[str, Any]] = field(default_factory=dict)
    reservations: list[Reservation] = field(default_factory=list)
    calendar: list[CalendarEntry] = field(default_factory=list)
    queue: list[dict[str, Any]] = field(default_factory=list)

    event_log: list[SchedulerEventRecord] = field(default_factory=list)
    cycle_tracker: dict[str, set[str]] = field(default_factory=dict)  # child → parent dependencies

    mode: QueueMode = QueueMode.NORMAL
    is_draining: bool = False
    drain_grace_seconds: int = 30


@dataclass
class SchedulerConfig:
    """Configuration for the scheduler including persistence settings (§M10)."""
    state_dir: str = "/srv/agentic/scheduler"
    persist_interval_seconds: float = 30.0
    auto_persist: bool = True


@dataclass
class Scheduler:
    """Admission controller and work scheduler.

    Invariants (§11):
    - OpenShell applies sandbox limits; this scheduler provides aggregate admission.
    - Optimization campaigns are background-interruptible, lower priority than interactive.
    - Administrative stop is immediate; no auto-restart without explicit authorization.
    - Campaigns never preempt prioritized user loads. (P0 requirement)
    """

    state: SchedulerState = field(default_factory=SchedulerState)
    config: SchedulerConfig = field(default_factory=SchedulerConfig)
    _last_persist_time: float = 0.0
    _collaboration_bot: Any = None

    # ── Admission ────────────────────────────────────────────────────────
    def admit(
        self,
        workload_id: str,
        required: ResourceLimits,
        priority: int = 50,  # 0-100, higher = more urgent
        mode: QueueMode = QueueMode.NORMAL,
        is_interactive: bool = True,
        user_id: str = "default",
    ) -> AdmissionResult:
        """Request resource admission for a workload."""
        if self.state.is_draining:
            return AdmissionResult(
                granted=False,
                reason="System is draining; new workloads rejected during grace period",
            )

        needed_cpu = required.cpus or 0.01  # minimum slice
        needed_mem = required.memory_mb or 64
        needed_gpu = required.gpu_count or 0

        # Account for fulfilled reservations when checking capacity (§M10)
        reserved_cpu = sum(r.required_cpu for r in self.state.reservations if r.fulfilled and not r.cancelled)
        reserved_mem = sum(r.required_memory_mb for r in self.state.reservations if r.fulfilled and not r.cancelled)
        reserved_gpu = sum(r.required_gpu for r in self.state.reservations if r.fulfilled and not r.cancelled)
        
        available_cpu = (self.state.total_cpu - self.state.allocated_cpu) - reserved_cpu
        available_mem = (self.state.total_memory_mb - self.state.allocated_memory_mb) - reserved_mem
        available_gpu = max(0, (self.state.total_gpu - self.state.allocated_gpu) - reserved_gpu)

        if mode == QueueMode.EXCLUSIVE:
            if needed_gpu > 0 and needed_gpu < self.state.total_gpu:
                return AdmissionResult(
                    granted=False, reason="Exclusive mode requires full GPU reservation",
                )

        if available_cpu < needed_cpu or available_mem < needed_mem or available_gpu < needed_gpu:
            return AdmissionResult(
                granted=False,
                reason=f"Insufficient resources (cpu:{available_cpu:.1f}/{needed_cpu}, "
                       f"mem:{available_mem}/{needed_mem}MB, gpu:{available_gpu}/{needed_gpu})",
            )

        # Parent/child aggregation check (§5.4)
        if self.state.active_workloads:
            parent_agg = self._aggregate_parent_children(workload_id, required)
            if not parent_agg["allowed"]:
                return AdmissionResult(granted=False, reason=parent_agg["reason"])

        # Grant admission
        self.state.allocated_cpu += needed_cpu
        self.state.allocated_memory_mb += needed_mem
        self.state.allocated_gpu += needed_gpu

        self.state.active_workloads[workload_id] = {
            "required": required,
            "priority": priority,
            "mode": mode,
            "is_interactive": is_interactive,
            "admitted_at": time.time(),
            "user_id": user_id,
            "metrics": {},
        }

        # Notify collaboration bot about admission (§M10)
        self._notify_collaboration_bot(
            event_type="workload_admitted",
            workload_id=workload_id,
            user_id=user_id,
            details={
                "cpu": needed_cpu,
                "memory_mb": needed_mem,
                "gpu": needed_gpu,
                "priority": priority,
                "mode": mode.value,
                "is_interactive": is_interactive,
            }
        )

        return AdmissionResult(
            granted=True,
            allocated={
                "cpu": needed_cpu,
                "memory_mb": needed_mem,
                "gpu": needed_gpu,
            },
        )

    def release(self, workload_id: str) -> bool:
        """Release previously admitted resources."""
        if workload_id not in self.state.active_workloads:
            return False
        w = self.state.active_workloads.pop(workload_id)
        req = w["required"]
        
        # Calculate duration for notification
        admitted_at = w.get("admitted_at", time.time())
        duration = time.time() - admitted_at
        
        self.state.allocated_cpu -= req.cpus or 0.01
        self.state.allocated_memory_mb -= req.memory_mb or 64
        self.state.allocated_gpu -= req.gpu_count or 0
        
        # Notify collaboration bot about release (§M10)
        self._notify_collaboration_bot(
            event_type="workload_released",
            workload_id=workload_id,
            details={
                "cpu": req.cpus or 0.01,
                "memory_mb": req.memory_mb or 64,
                "gpu": req.gpu_count or 0,
                "duration": f"{duration:.1f}s",
            }
        )
        
        return True

    def submit_to_queue(self, workload_id: str, required: ResourceLimits, priority: int = 50) -> None:
        """Queue a workload for deferred admission."""
        self.state.queue.append({
            "workload_id": workload_id,
            "required": required,
            "priority": priority,
            "submitted_at": time.time(),
            "status": "queued",
        })

    # ── Multi-agent aggregation (§5.4) ───────────────────────────────────
    def _aggregate_parent_children(
        self, parent_id: str, child_required: ResourceLimits
    ) -> dict[str, Any]:
        """Aggregate CPU, memory, GPU, tokens, costs, and external access across tree."""
        total_child_cpu = child_required.cpus or 0.01
        total_child_mem = child_required.memory_mb or 64
        total_child_gpu = child_required.gpu_count or 0

        # Check existing children allocation for this parent
        for wid, wdata in self.state.active_workloads.items():
            if wdata.get("parent_id") == parent_id:
                req = wdata["required"]
                total_child_cpu += req.cpus or 0.01
                total_child_mem += req.memory_mb or 64
                total_child_gpu += req.gpu_count or 0

        # Enforce hierarchy limits (child gets no more than parent)
        # This is a structural invariant; actual enforcement happens in Docker
        if total_child_cpu > (self.state.total_cpu * 0.9):
            return {"allowed": False, "reason": "Parent tree exceeds 90% CPU budget"}

        return {"allowed": True, "aggregated": {
            "cpu": total_child_cpu, "memory_mb": total_child_mem, "gpu": total_child_gpu,
        }}

    # ── Modes & Drain ────────────────────────────────────────────────────
    def set_mode(self, mode: QueueMode) -> None:
        self.state.mode = mode

    def start_drain(self, grace_seconds: int = 30) -> None:
        self.state.is_draining = True
        self.state.drain_grace_seconds = grace_seconds

    def end_drain(self) -> None:
        self.state.is_draining = False

    # ── Metrics & Reporting ──────────────────────────────────────────────
    def utilization(self) -> dict[str, float]:
        total_cpu = max(self.state.total_cpu, 0.001)
        return {
            "cpu_pct": (self.state.allocated_cpu / total_cpu) * 100,
            "memory_pct": (self.state.allocated_memory_mb / max(self.state.total_memory_mb, 1)) * 100,
            "gpu_pct": (self.state.allocated_gpu / max(self.state.total_gpu, 1)) * 100 if self.state.total_gpu > 0 else 0,
        }

    def list_active_workloads(self) -> list[dict[str, Any]]:
        return list(self.state.active_workloads.values())

    def list_queued_workloads(self) -> list[dict[str, Any]]:
        return sorted(
            [w for w in self.state.queue if w["status"] == "queued"],
            key=lambda x: x["priority"],
            reverse=True,
        )


    # ── Calendar & Reservations (§M10) ────────────────────────────────
    
    def create_reservation(
        self,
        workload_id: str,
        user_id: str,
        start_time: float,
        end_time: float,
        required_cpu: float = 0.5,
        required_memory_mb: int = 512,
        required_gpu: int = 0,
        priority: int = 50,
    ) -> Reservation:
        """Create a resource reservation for future use (§M10)."""
        res = Reservation(
            workload_id=workload_id,
            user_id=user_id,
            start_time=start_time,
            end_time=end_time,
            required_cpu=required_cpu,
            required_memory_mb=required_memory_mb,
            required_gpu=required_gpu,
            priority=priority,
        )
        self.state.reservations.append(res)
        self.state.event_log.append(SchedulerEventRecord(
            event_type=SchedulerEvent.RESERVATION_CREATED,
            workload_id=workload_id,
            details={"start": start_time, "end": end_time},
        ))
        
        # Notify collaboration bot about reservation (§M10)
        self._notify_collaboration_bot(
            event_type="reservation_created",
            workload_id=workload_id,
            user_id=user_id,
            details={
                "start": start_time,
                "end": end_time,
                "cpu": required_cpu,
                "memory_mb": required_memory_mb,
                "gpu": required_gpu,
                "priority": priority,
            }
        )
        
        return res

    def cancel_reservation(self, reservation_id: str) -> bool:
        """Cancel a reservation."""
        for res in self.state.reservations:
            if res.reservation_id == reservation_id and not res.fulfilled:
                res.cancelled = True
                self.state.event_log.append(SchedulerEventRecord(
                    event_type=SchedulerEvent.RESERVATION_EXPIRED,
                    workload_id=res.workload_id,
                    details={"reason": "cancelled"},
                ))
                return True
        return False

    def get_available_capacity_with_reservations(self) -> dict[str, float]:
        """Calculate capacity accounting for fulfilled reservations."""
        reserved_cpu = sum(r.required_cpu for r in self.state.reservations if r.fulfilled and not r.cancelled)
        reserved_mem = sum(r.required_memory_mb for r in self.state.reservations if r.fulfilled and not r.cancelled)
        reserved_gpu = sum(r.required_gpu for r in self.state.reservations if r.fulfilled and not r.cancelled)
        
        return {
            "available_cpu": (self.state.total_cpu - self.state.allocated_cpu) - reserved_cpu,
            "available_memory_mb": (self.state.total_memory_mb - self.state.allocated_memory_mb) - reserved_mem,
            "available_gpu": max(0, (self.state.total_gpu - self.state.allocated_gpu) - reserved_gpu),
        }

    def create_calendar_entry(
        self,
        workload_id: str,
        user_id: str,
        scheduled_start: float,
        scheduled_end: float,
        resource_limits: dict[str, Any],
        priority: int = 50,
    ) -> CalendarEntry:
        """Schedule a workload for future admission (§M10)."""
        entry = CalendarEntry(
            workload_id=workload_id,
            user_id=user_id,
            scheduled_start=scheduled_start,
            scheduled_end=scheduled_end,
            resource_limits=resource_limits,
            priority=priority,
        )
        self.state.calendar.append(entry)
        return entry

    def check_calendar_and_admit(self, now: float | None = None) -> list[str]:
        """Check calendar for ready entries and admit them. Returns admitted workload IDs."""
        if now is None:
            now = time.time()
        
        admitted = []
        to_remove = []
        
        for i, entry in enumerate(self.state.calendar):
            if entry.triggered or entry.scheduled_start > now:
                continue
            
            # Try to admit this workload with its scheduled resources
            limits = ResourceLimits(
                cpus=entry.resource_limits.get("cpus", 0.5),
                memory_mb=entry.resource_limits.get("memory_mb", 512),
                gpu_count=entry.resource_limits.get("gpu_count", 0),
                storage_gb=entry.resource_limits.get("storage_gb", 0),
            )
            
            result = self.admit(
                workload_id=entry.workload_id,
                required=limits,
                priority=entry.priority,
                mode=QueueMode.NORMAL,
                is_interactive=False,
            )
            
            if result.granted:
                entry.triggered = True
                admitted.append(entry.workload_id)
                self.state.event_log.append(SchedulerEventRecord(
                    event_type=SchedulerEvent.CALENDAR_TRIGGERED,
                    workload_id=entry.workload_id,
                    details={"scheduled_at": entry.scheduled_start},
                ))
                
                # Notify collaboration bot about calendar event (§M10)
                self._notify_collaboration_bot(
                    event_type="calendar_triggered",
                    workload_id=entry.workload_id,
                    user_id=entry.user_id,
                    details={
                        "scheduled_at": entry.scheduled_start,
                        "resources": entry.resource_limits,
                    }
                )
            to_remove.append(i)
        
        # Remove processed entries (keep failed ones for retry)
        if admitted:
            self.state.calendar = [e for e in self.state.calendar if not e.triggered or e.scheduled_end < now]
        
        return admitted

    # ── Cooperative Preemption (§M10) ─────────────────────────────────
    
    def preempt_if_needed(
        self,
        high_priority_id: str,
        required: ResourceLimits,
        minimum_priority: int = 50,
    ) -> list[str]:
        """Preempt lower-priority workloads to make room for a high-priority request (§M10).
        
        Returns list of preempted workload IDs.
        """
        preempted = []
        
        # Sort active workloads by priority (lowest first)
        candidates = [
            (wid, wdata) 
            for wid, wdata in self.state.active_workloads.items()
            if wdata.get("priority", 50) < minimum_priority and not wdata.get("is_interactive", True)
        ]
        candidates.sort(key=lambda x: x[1].get("priority", 50))
        
        needed_cpu = required.cpus or 0.01
        needed_mem = required.memory_mb or 64
        needed_gpu = required.gpu_count or 0
        
        freed_cpu = 0.0
        freed_mem = 0
        freed_gpu = 0
        
        for wid, wdata in candidates:
            if freed_cpu >= needed_cpu and freed_mem >= needed_mem and freed_gpu >= needed_gpu:
                break
            
            req = wdata["required"]
            self.release(wid)  # release() will handle collaboration notification
            preempted.append(wid)
            freed_cpu += req.cpus or 0.01
            freed_mem += req.memory_mb or 64
            freed_gpu += req.gpu_count or 0
            
            self.state.event_log.append(SchedulerEventRecord(
                event_type=SchedulerEvent.WORKLOAD_PREEMPTED,
                workload_id=wid,
                details={"reason": f"preempted by {high_priority_id} (priority {minimum_priority})"},
            ))
            
            # Notify collaboration bot about preemption (§M10)
            self._notify_collaboration_bot(
                event_type="workload_preempted",
                workload_id=wid,
                details={
                    "reason": f"preempted by {high_priority_id} (priority {minimum_priority})",
                    "preempted_by": high_priority_id,
                    "cpu": req.cpus or 0.01,
                    "memory_mb": req.memory_mb or 64,
                    "gpu": req.gpu_count or 0,
                }
            )
        
        return preempted

    # ── Anti-Loop Detection (§5.4) ────────────────────────────────────
    
    def add_dependency(self, child_id: str, parent_id: str) -> bool:
        """Track parent-child dependency for cycle detection (§5.4)."""
        if child_id not in self.state.cycle_tracker:
            self.state.cycle_tracker[child_id] = set()
        
        # Direct cycle check
        if parent_id == child_id:
            return False  # Self-reference is a cycle
        
        # Check if adding this edge creates a cycle
        visited = set()
        stack = [parent_id]
        while stack:
            current = stack.pop()
            if current == child_id:
                return False  # Cycle detected
            
            if current in visited:
                continue
            visited.add(current)
            
            for dep_parent in self.state.cycle_tracker.get(current, set()):
                stack.append(dep_parent)
        
        self.state.cycle_tracker[child_id].add(parent_id)
        return True

    def detect_cycles(self) -> list[set[str]]:
        """Detect cycles in the dependency graph. Returns lists of workloads forming cycles."""
        visited = set()
        rec_stack = set()
        cycles = []
        
        def dfs(node, path):
            visited.add(node)
            rec_stack.add(node)
            path.append(node)
            
            for parent in self.state.cycle_tracker.get(node, set()):
                if parent not in visited:
                    cycle = dfs(parent, path)
                    if cycle:
                        cycles.append(cycle)
                elif parent in rec_stack:
                    # Found cycle
                    cycle_start = path.index(parent)
                    cycles.append(set(path[cycle_start:]))
            
            path.pop()
            rec_stack.discard(node)
            return None
        
        for node in list(self.state.cycle_tracker.keys()):
            if node not in visited:
                dfs(node, [])
        
        return cycles

    def is_acyclic(self, child_id: str, parent_id: str) -> bool:
        """Check if adding a child→parent edge would create a cycle."""
        # Temporarily add and check
        temp_deps = self.state.cycle_tracker.get(child_id, set()).copy()
        self.state.cycle_tracker[child_id] = temp_deps | {parent_id}
        
        cycles = self.detect_cycles()
        
        # Restore original state
        if cycles:
            self.state.cycle_tracker[child_id] = temp_deps
        
        return len(cycles) == 0

    def get_orphan_workloads(self) -> list[str]:
        """Find workloads whose parent has been released (orphans)."""
        orphans = []
        for wid, wdata in self.state.active_workloads.items():
            parent_id = wdata.get("parent_id")
            if parent_id and parent_id not in self.state.active_workloads:
                orphans.append(wid)
        return orphans

    def drain_orphans(self, grace_seconds: int = 30) -> list[str]:
        """Drain orphaned workloads after grace period."""
        orphans = self.get_orphan_workloads()
        drained = []
        
        for wid in orphans:
            # Check if grace period has passed
            wdata = self.state.active_workloads[wid]
            admitted_at = wdata.get("admitted_at", 0)
            if time.time() - admitted_at > grace_seconds:
                self.release(wid)
                drained.append(wid)
        
        return drained


# ── Additional API methods needed by control plane ─────────────────────

    def track_workload(
        self,
        workload_id: str,
        required: ResourceLimits,
        user_id: str = "default",
    ) -> None:
        """Track a workload in active state after admission."""
        self.state.active_workloads[workload_id] = {
            "required": required,
            "user_id": user_id,
            "started_at": time.time(),
            "status": "active",
        }

    def resume_after_drain(self) -> None:
        """Resume accepting workloads after drain period."""
        self.state.is_draining = False

    # ── File-based Persistence (§M10) ───────────────────────────────────────

    def _get_state_file_path(self) -> Path:
        """Get the path for the scheduler state file."""
        return Path(self.config.state_dir) / "scheduler_state.json"

    def _get_event_log_path(self) -> Path:
        """Get the path for the event log file."""
        return Path(self.config.state_dir) / "scheduler_events.json"

    def _serialize_state(self) -> dict[str, Any]:
        """Serialize scheduler state for persistence."""
        state_dict = {
            "total_cpu": self.state.total_cpu,
            "total_memory_mb": self.state.total_memory_mb,
            "total_gpu": self.state.total_gpu,
            "total_storage_gb": self.state.total_storage_gb,
            "allocated_cpu": self.state.allocated_cpu,
            "allocated_memory_mb": self.state.allocated_memory_mb,
            "allocated_gpu": self.state.allocated_gpu,
            "allocated_storage_gb": self.state.allocated_storage_gb,
            "active_workloads": self.state.active_workloads,
            "reservations": [asdict(r) for r in self.state.reservations],
            "calendar": [asdict(c) for c in self.state.calendar],
            "queue": self.state.queue,
            "event_log": [asdict(e) for e in self.state.event_log],
            "cycle_tracker": {k: list(v) for k, v in self.state.cycle_tracker.items()},
            "mode": self.state.mode.value,
            "is_draining": self.state.is_draining,
            "drain_grace_seconds": self.state.drain_grace_seconds,
        }
        return state_dict

    def _deserialize_state(self, state_dict: dict[str, Any]) -> None:
        """Deserialize scheduler state from persistence."""
        self.state.total_cpu = state_dict.get("total_cpu", 0.0)
        self.state.total_memory_mb = state_dict.get("total_memory_mb", 0)
        self.state.total_gpu = state_dict.get("total_gpu", 0)
        self.state.total_storage_gb = state_dict.get("total_storage_gb", 0)
        self.state.allocated_cpu = state_dict.get("allocated_cpu", 0.0)
        self.state.allocated_memory_mb = state_dict.get("allocated_memory_mb", 0)
        self.state.allocated_gpu = state_dict.get("allocated_gpu", 0)
        self.state.allocated_storage_gb = state_dict.get("allocated_storage_gb", 0)
        self.state.active_workloads = state_dict.get("active_workloads", {})
        self.state.reservations = [
            Reservation(**r) for r in state_dict.get("reservations", [])
        ]
        self.state.calendar = [
            CalendarEntry(**c) for c in state_dict.get("calendar", [])
        ]
        self.state.queue = state_dict.get("queue", [])
        self.state.event_log = [
            SchedulerEventRecord(**e) for e in state_dict.get("event_log", [])
        ]
        self.state.cycle_tracker = {
            k: set(v) for k, v in state_dict.get("cycle_tracker", {}).items()
        }
        self.state.mode = QueueMode(state_dict.get("mode", "normal"))
        self.state.is_draining = state_dict.get("is_draining", False)
        self.state.drain_grace_seconds = state_dict.get("drain_grace_seconds", 30)

    def save_state(self, state_file: str | Path | None = None) -> bool:
        """Save scheduler state to file (§M10).
        
        Args:
            state_file: Optional custom path. Uses config.state_dir if None.
            
        Returns:
            True if save was successful, False otherwise.
        """
        try:
            # Ensure directory exists
            state_path = Path(state_file) if state_file else self._get_state_file_path()
            state_path.parent.mkdir(parents=True, exist_ok=True)
            
            # Serialize and save state
            state_dict = self._serialize_state()
            with open(state_path, "w", encoding="utf-8") as f:
                json.dump(state_dict, f, indent=2, default=str)
            
            # Save event log separately for audit purposes
            event_log_path = self._get_event_log_path()
            event_log_data = {
                "events": [asdict(e) for e in self.state.event_log],
                "last_updated": time.time()
            }
            with open(event_log_path, "w", encoding="utf-8") as f:
                json.dump(event_log_data, f, indent=2, default=str)
            
            self._last_persist_time = time.time()
            return True
            
        except Exception as e:
            # Log error but don't fail the scheduler
            self.state.event_log.append(SchedulerEventRecord(
                event_type=SchedulerEvent.WORKLOAD_RELEASED,
                workload_id="persistence-error",
                details={"error": str(e), "operation": "save_state"},
            ))
            return False

    def load_state(self, state_file: str | Path | None = None) -> bool:
        """Load scheduler state from file (§M10).
        
        Args:
            state_file: Optional custom path. Uses config.state_dir if None.
            
        Returns:
            True if load was successful, False otherwise.
        """
        try:
            state_path = Path(state_file) if state_file else self._get_state_file_path()
            if not state_path.exists():
                return False
            
            # Load and deserialize state
            with open(state_path, "r", encoding="utf-8") as f:
                state_dict = json.load(f)
            
            self._deserialize_state(state_dict)
            self._last_persist_time = time.time()
            return True
            
        except Exception as e:
            # Log error but don't fail the scheduler
            self.state.event_log.append(SchedulerEventRecord(
                event_type=SchedulerEvent.WORKLOAD_RELEASED,
                workload_id="persistence-error",
                details={"error": str(e), "operation": "load_state"},
            ))
            return False

    def maybe_persist(self) -> bool:
        """Automatically persist state if interval has elapsed (§M10).
        
        Returns:
            True if persistence occurred, False otherwise.
        """
        if not self.config.auto_persist:
            return False
        
        now = time.time()
        if now - self._last_persist_time < self.config.persist_interval_seconds:
            return False
        
        return self.save_state()

    # ── Collaboration Integration (§M10) ─────────────────────────────────

    def set_collaboration_bot(self, bot: Any) -> None:
        """Set the collaboration bot for scheduler notifications (§M10).
        
        Args:
            bot: A SchedulerNotificationBot instance or compatible bot.
        """
        self._collaboration_bot = bot

    def _notify_collaboration_bot(
        self,
        event_type: str,
        workload_id: str,
        user_id: str = "",
        details: dict[str, Any] | None = None,
    ) -> bool:
        """Notify the collaboration bot about a scheduler event (§M10).
        
        Args:
            event_type: Scheduler event type
            workload_id: ID of the workload
            user_id: User who owns the workload
            details: Additional event details
            
        Returns:
            True if notification was queued successfully.
        """
        if not self._collaboration_bot:
            return False
        
        try:
            return self._collaboration_bot.notify_scheduler_event(
                event_type=event_type,
                workload_id=workload_id,
                user_id=user_id,
                details=details,
            )
        except Exception:
            # Don't let collaboration failures affect scheduler operation
            return False
