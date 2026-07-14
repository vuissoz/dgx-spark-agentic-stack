"""src/agentic/evaluation/shadow_canari.py - M11 Shadow deployment & canary analysis scaffolding.

Implements:
- Shadow task mirroring (v1/v2 dual execution with correlation)
- Canary user/agent/application traffic splitting
- Comparative metric collection and statistical analysis
- Rollback chronometry (timed rollback testing)

Conforms to PLAN.md M11 (Ombre et canaris), 15.4.10 (shadow/canari step).

NOTES:
- This module provides the evaluation framework; actual execution requires
  runtime resources (DGX Spark, docker-compose, running services).
- In rootless-dev mode without live services, the module returns stubbed evidence.
"""

from __future__ import annotations

import dataclasses
import enum
import json
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Optional


# -- Enums ----------------------------------------------------------------

class ShadowMode(enum.Enum):
    MIRROR = "mirror"
    SPLIT_TRAFFIC = "split"


class CanaryStrategy(enum.Enum):
    PER_USER = "per-user"
    PER_AGENT = "per-agent"
    PER_APP = "per-app"


# -- Data Classes ---------------------------------------------------------

@dataclass(frozen=True)
class ShadowTask:
    task_id: str
    source_task_id: Optional[str]
    user_id: str
    agent_identity: str
    project: Optional[str]
    payload: dict[str, Any]
    created_at: str = field(default_factory=lambda: datetime.now(UTC).isoformat())


@dataclass(frozen=True)
class TaskResult:
    task_id: str
    pipeline: str
    success: bool
    latency_ms: Optional[float]
    metrics: dict[str, Any] = field(default_factory=dict)
    error: Optional[str] = None
    correlation_id: Optional[str] = None


@dataclass(frozen=True)
class ShadowComparison:
    shadow_task_id: str
    v1_result: Optional[TaskResult]
    v2_result: Optional[TaskResult]
    correlation_id: str
    created_at: str = field(default_factory=lambda: datetime.now(UTC).isoformat())

    @property
    def both_success(self) -> bool:
        return (self.v1_result is not None and self.v1_result.success
                and self.v2_result is not None and self.v2_result.success)

    @property
    def v1_better_latency(self) -> bool:
        if self.v1_result and self.v2_result:
            return (self.v1_result.latency_ms or 0) < (self.v2_result.latency_ms or 0)
        return False

    @property
    def v2_better_latency(self) -> bool:
        if self.v1_result and self.v2_result:
            return (self.v2_result.latency_ms or 0) < (self.v1_result.latency_ms or 0)
        return False


@dataclass(frozen=True)
class ShadowDeploymentState:
    deployment_id: str
    mode: ShadowMode
    canary_strategy: Optional[CanaryStrategy]
    traffic_split_pct: float = 0.0
    active_shadow_tasks: list[str] = field(default_factory=list)
    completed_comparisons: int = 0
    started_at: str = field(default_factory=lambda: datetime.now(UTC).isoformat())


@dataclass(frozen=True)
class RollbackChronometry:
    operation: str
    start_time: str
    end_time: Optional[str] = None
    duration_ms: Optional[float] = None
    success: bool = True
    error: Optional[str] = None


# -- Shadow Deployment Manager --------------------------------------------

class ShadowDeploymentManager:
    """Manages shadow task mirroring and canary traffic splitting (M11)."""

    def __init__(self, state_dir: Optional[Path] = None) -> None:
        self.state_dir = state_dir or Path("/tmp/dgx-spark-shadow")
        self.comparisons: list[ShadowComparison] = []
        self.shadow_tasks: dict[str, ShadowTask] = {}

    def create_deployment(self, mode: ShadowMode, canary_strategy: Optional[CanaryStrategy] = None, traffic_split_pct: float = 10.0) -> str:
        deployment_id = f"shadow-{uuid.uuid4().hex[:8]}"
        state_file = self.state_dir / f"{deployment_id}.json"
        self.state_dir.mkdir(parents=True, exist_ok=True)
        with open(state_file, "w") as f:
            json.dump({
                "mode": mode.value,
                "canary_strategy": canary_strategy.value if canary_strategy else None,
                "traffic_split_pct": traffic_split_pct,
                "started_at": datetime.now(UTC).isoformat(),
            }, f, indent=2)
        return deployment_id

    def submit_shadow_task(self, source_task_id: Optional[str], user_id: str, agent_identity: str, project: Optional[str], payload: dict[str, Any]) -> ShadowTask:
        shadow_id = f"shadow-{uuid.uuid4().hex[:8]}"
        task = ShadowTask(task_id=shadow_id, source_task_id=source_task_id, user_id=user_id, agent_identity=agent_identity, project=project, payload=payload)
        self.shadow_tasks[shadow_id] = task
        return task

    def run_comparison(self, shadow_task_id: str, v1_result: Optional[TaskResult] = None, v2_result: Optional[TaskResult] = None) -> ShadowComparison:
        correlation_id = f"corr-{uuid.uuid4().hex[:8]}"
        comparison = ShadowComparison(shadow_task_id=shadow_task_id, v1_result=v1_result, v2_result=v2_result, correlation_id=correlation_id)
        self.comparisons.append(comparison)
        return comparison

    def get_statistics(self) -> dict[str, Any]:
        total = len(self.comparisons)
        both_success = sum(1 for c in self.comparisons if c.both_success)
        v1_better = sum(1 for c in self.comparisons if c.v1_better_latency)
        v2_better = sum(1 for c in self.comparisons if c.v2_better_latency)
        return {
            "total_comparisons": total,
            "both_success": both_success,
            "v1_better_latency": v1_better,
            "v2_better_latency": v2_better,
            "tps_v2_improvement_pct": ((v2_better - v1_better) / total * 100 if total > 0 else 0),
        }

    def serialize_report(self) -> dict[str, Any]:
        return {
            "schema_version": "1.0",
            "evaluation_id": f"m11-{uuid.uuid4().hex[:8]}",
            "generated_at": datetime.now(UTC).isoformat(),
            "total_comparisons": len(self.comparisons),
            "statistics": self.get_statistics(),
            "comparisons": [{"shadow_task_id": c.shadow_task_id, "v1_success": c.v1_result.success if c.v1_result else None, "v2_success": c.v2_result.success if c.v2_result else None, "correlation_id": c.correlation_id} for c in self.comparisons[:100]],
        }


# -- Rollback Tester ------------------------------------------------------

class RollbackTester:
    """Tests rollback timing and success (M11 requirement)."""

    def __init__(self) -> None:
        self.timings: list[RollbackChronometry] = []

    def measure(self, operation: str) -> RollbackChronometry:
        timing = RollbackChronometry(operation=operation, start_time=datetime.now(UTC).isoformat())
        self.timings.append(timing)
        return timing

    def complete(self, timing: RollbackChronometry, success: bool = True, error: Optional[str] = None) -> None:
        now = datetime.now(UTC).isoformat()
        start = datetime.fromisoformat(timing.start_time)
        end = datetime.fromisoformat(now)
        idx = self.timings.index(timing)
        new_timing = dataclasses.replace(timing, end_time=now, duration_ms=(end - start).total_seconds() * 1000, success=success, error=error)
        self.timings[idx] = new_timing

    def get_summary(self) -> dict[str, Any]:
        timed = [t for t in self.timings if t.duration_ms is not None]
        if not timed:
            return {"operations_measured": 0}
        durations = [t.duration_ms for t in timed]
        return {
            "operations_measured": len(timed),
            "all_success": all(t.success for t in timed),
            "min_ms": min(durations),
            "max_ms": max(durations),
            "mean_ms": sum(durations) / len(durations),
        }


# -- Validation Helper ----------------------------------------------------

def m11_validation_stub() -> dict[str, Any]:
    """Stub validation for M11 when running without hardware/runtime."""
    manager = ShadowDeploymentManager()
    deployment_id = manager.create_deployment(ShadowMode.MIRROR)
    task = manager.submit_shadow_task(source_task_id="test-task-1", user_id="test-user", agent_identity="codex", project="test-project", payload={"type": "m11-validation"})
    comparison = manager.run_comparison(task.task_id)

    return {
        "status": "framework_ready_but_requires_runtime",
        "deployment_id": deployment_id,
        "shadow_task_id": task.task_id,
        "comparison_id": comparison.correlation_id,
        "requirements": [
            "DGX Spark hardware with running v1 and v2 services",
            "docker-compose environment for shadow task routing",
            "v1/v2 pipeline endpoints accessible for mirroring",
            "Statistical threshold configuration per section 15.4.8",
        ],
    }


# -- Main (self-test) -----------------------------------------------------

if __name__ == "__main__":
    # Quick self-test
    manager = ShadowDeploymentManager()
    dep_id = manager.create_deployment(ShadowMode.MIRROR, CanaryStrategy.PER_USER)
    assert dep_id.startswith("shadow-"), f"Expected deployment id starting with 'shadow-', got: {dep_id}"

    task1 = manager.submit_shadow_task(None, "user1", "codex", "proj1", {"prompt": "hello"})
    task2 = manager.submit_shadow_task("v1-task-001", "user2", "claude", None, {"prompt": "world"})

    # Simulate results
    r1_v1 = TaskResult(task1.task_id, "v1", True, 120.5, correlation_id="c1")
    r1_v2 = TaskResult(task1.task_id, "v2", True, 98.2, correlation_id="c1")
    comp1 = manager.run_comparison(task1.task_id, r1_v1, r1_v2)

    assert comp1.both_success is True
    assert comp1.v2_better_latency is True

    # Test rollback timing
    tester = RollbackTester()
    t1 = tester.measure("rollback-all")
    import time
    time.sleep(0.01)
    tester.complete(t1, success=True)

    summary = tester.get_summary()
    assert summary["operations_measured"] == 1
    assert summary["all_success"] is True

    print("M11 shadow/canari module: self-test PASSED")
