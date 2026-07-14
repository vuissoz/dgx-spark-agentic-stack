"""tests/J26_m11_shadow_canari.py -- M11 Shadow deployment & canary analysis validation.

Tests the shadow/canari framework scaffolding (PLAN.md M11).

Run: python3 tests/J26_m11_shadow_canari.py
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "src"))

from agentic.evaluation.shadow_canari import (
    ShadowDeploymentManager,
    ShadowMode,
    CanaryStrategy,
    TaskResult,
    ShadowComparison,
    RollbackTester,
    m11_validation_stub,
)

passed = 0
failed = 0


def ok(name: str) -> None:
    global passed
    print(f"PASS: J26-{name}")
    passed += 1


def fail(name: str, reason: str) -> None:
    global failed
    print(f"FAIL: J26-{name}: {reason}", file=sys.stderr)
    failed += 1


def test_create_deployment_mirror() -> None:
    mgr = ShadowDeploymentManager()
    dep_id = mgr.create_deployment(ShadowMode.MIRROR)
    assert dep_id.startswith("shadow-"), f"Expected deployment id starting with 'shadow-', got: {dep_id}"
    ok("create_deployment_mirror")


def test_create_deployment_canary() -> None:
    mgr = ShadowDeploymentManager()
    dep_id = mgr.create_deployment(ShadowMode.SPLIT_TRAFFIC, CanaryStrategy.PER_USER, 25.0)
    assert dep_id.startswith("shadow-")
    ok("create_deployment_canary")


def test_submit_shadow_task() -> None:
    mgr = ShadowDeploymentManager()
    task = mgr.submit_shadow_task("v1-orig", "alice", "codex", "proj-x", {"prompt": "test"})
    assert task.task_id.startswith("shadow-")
    assert task.user_id == "alice"
    assert task.agent_identity == "codex"
    ok("submit_shadow_task")


def test_run_comparison_both_success() -> None:
    mgr = ShadowDeploymentManager()
    task = mgr.submit_shadow_task(None, "user1", "claude", None, {})
    r1 = TaskResult(task.task_id, "v1", True, 100.0)
    r2 = TaskResult(task.task_id, "v2", True, 90.0)
    comp = mgr.run_comparison(task.task_id, r1, r2)
    assert comp.both_success is True
    ok("run_comparison_both_success")


def test_run_comparison_latency() -> None:
    mgr = ShadowDeploymentManager()
    task = mgr.submit_shadow_task(None, "user1", "opencode", None, {})
    # v1 slower than v2
    r_v1 = TaskResult(task.task_id, "v1", True, 200.0)
    r_v2 = TaskResult(task.task_id, "v2", True, 150.0)
    comp = mgr.run_comparison(task.task_id, r_v1, r_v2)
    assert comp.v2_better_latency is True
    assert comp.v1_better_latency is False

    # v1 faster than v2 (different task to avoid ID collision)
    task2 = mgr.submit_shadow_task(None, "user1b", "opencode", None, {})
    r_v1_faster = TaskResult(task2.task_id, "v1", True, 80.0)
    r_v2_slower = TaskResult(task2.task_id, "v2", True, 250.0)
    comp2 = mgr.run_comparison(task2.task_id, r_v1_faster, r_v2_slower)
    assert comp2.v1_better_latency is True
    assert comp2.v2_better_latency is False
    ok("run_comparison_latency")


def test_statistics_aggregation() -> None:
    mgr = ShadowDeploymentManager()
    # Task 1: v2 faster (90 < 100) -> v2_better
    t1 = mgr.submit_shadow_task(None, "u1", "a1", None, {})
    mgr.run_comparison(t1.task_id, TaskResult(t1.task_id, "v1", True, 100.0), TaskResult(t1.task_id, "v2", True, 90.0))

    # Task 2: v1 faster (80 < 200) -> v1_better
    t2 = mgr.submit_shadow_task(None, "u2", "a2", None, {})
    mgr.run_comparison(t2.task_id, TaskResult(t2.task_id, "v1", True, 80.0), TaskResult(t2.task_id, "v2", True, 200.0))

    # Task 3: v1 faster (150 < 160) -> v1_better
    t3 = mgr.submit_shadow_task(None, "u3", "a3", None, {})
    mgr.run_comparison(t3.task_id, TaskResult(t3.task_id, "v1", True, 150.0), TaskResult(t3.task_id, "v2", True, 160.0))

    stats = mgr.get_statistics()
    assert stats["total_comparisons"] == 3
    assert stats["both_success"] == 3
    assert stats["v1_better_latency"] == 2, f"Expected 2 v1_better, got {stats['v1_better_latency']}"
    assert stats["v2_better_latency"] == 1, f"Expected 1 v2_better, got {stats['v2_better_latency']}"
    ok("statistics_aggregation")


def test_rollback_timing() -> None:
    import time
    tester = RollbackTester()
    t1 = tester.measure("snapshot")
    time.sleep(0.01)
    tester.complete(t1, success=True)

    summary = tester.get_summary()
    assert summary["operations_measured"] == 1
    assert summary["all_success"] is True
    assert summary["min_ms"] >= 0
    ok("rollback_timing")


def test_m11_validation_stub() -> None:
    result = m11_validation_stub()
    assert result["status"] == "framework_ready_but_requires_runtime"
    assert "deployment_id" in result
    assert len(result["requirements"]) >= 4
    ok("m11_validation_stub")


def test_serialize_report() -> None:
    mgr = ShadowDeploymentManager()
    dep = mgr.create_deployment(ShadowMode.MIRROR)
    task = mgr.submit_shadow_task(None, "u1", "codex", None, {})
    mgr.run_comparison(task.task_id, TaskResult(task.task_id, "v1", True, 100.0), TaskResult(task.task_id, "v2", True, 95.0))

    report = mgr.serialize_report()
    assert "evaluation_id" in report
    assert "total_comparisons" in report
    assert report["total_comparisons"] == 1
    assert len(report["comparisons"]) == 1
    ok("serialize_report")


if __name__ == "__main__":
    test_create_deployment_mirror()
    test_create_deployment_canary()
    test_submit_shadow_task()
    test_run_comparison_both_success()
    test_run_comparison_latency()
    test_statistics_aggregation()
    test_rollback_timing()
    test_m11_validation_stub()
    test_serialize_report()

    print(f"\n=== J26_m11_shadow_canari: PASS={passed} FAIL={failed} ===")
    sys.exit(1 if failed else 0)
