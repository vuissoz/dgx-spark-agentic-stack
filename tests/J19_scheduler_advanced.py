"""tests/J19_scheduler_advanced.py — §M10 Scheduler advanced features.

Validates:
- Calendar-based scheduling and admission
- Reservation creation, fulfillment, and cancellation
- Cooperative preemption of lower-priority workloads
- Anti-loop cycle detection in multi-agent dependency trees

Tests:
- J19-1: Calendar entries are triggered at scheduled time
- J19-2: Reservations block capacity until fulfilled
- J19-3: Preemption frees resources for higher-priority workloads
- J19-4: Cycle detection prevents circular dependencies
- J19-5: Orphan workload detection and draining
"""

import sys
import time
sys.path.insert(0, "src")

from agentic.control.scheduler import (
    Scheduler, ResourceLimits, QueueMode, AdmissionResult,
    Reservation, CalendarEntry, SchedulerEventRecord, SchedulerEvent,
)


def test_calendar_admission():
    """J19-1: Calendar entries are triggered at scheduled time.
    
    Verifies that calendar-based scheduling admits workloads when their
    scheduled_start time arrives.
    """
    sched = Scheduler()
    # Set system capacity
    sched.state.total_cpu = 2.0
    sched.state.total_memory_mb = 2048
    sched.state.total_gpu = 1
    
    now = time.time()
    
    # Create calendar entries for future times
    entry1 = sched.create_calendar_entry(
        workload_id="cal-wl-1",
        user_id="alice",
        scheduled_start=now - 60,  # Already ready (in past)
        scheduled_end=now + 300,
        resource_limits={"cpus": 0.5, "memory_mb": 512, "gpu_count": 0},
    )
    
    entry2 = sched.create_calendar_entry(
        workload_id="cal-wl-2",
        user_id="bob",
        scheduled_start=now + 3600,  # Future (not ready)
        scheduled_end=now + 4000,
        resource_limits={"cpus": 0.5, "memory_mb": 512, "gpu_count": 0},
    )
    
    # Check calendar and admit ready entries
    admitted = sched.check_calendar_and_admit(now)
    
    assert "cal-wl-1" in admitted, f"cal-wl-1 should be admitted, got: {admitted}"
    assert "cal-wl-2" not in admitted, f"cal-wl-2 should NOT be admitted yet"
    assert len(admitted) == 1, f"Expected exactly 1 admission, got {len(admitted)}"
    
    # Verify entry1 is triggered
    assert entry1.triggered, "entry1 should be marked as triggered"
    
    print("PASS: J19-1_calendar_admission")


def test_reservations_block_capacity():
    """J19-2: Reservations block capacity until fulfilled.
    
    Verifies that reservations consume capacity and prevent over-allocation.
    """
    sched = Scheduler()
    # Set limited capacity
    sched.state.total_cpu = 1.0
    sched.state.total_memory_mb = 1024
    sched.state.total_gpu = 0
    
    now = time.time()
    
    # Create a reservation that will consume all CPU when fulfilled
    res = sched.create_reservation(
        workload_id="res-wl",
        user_id="charlie",
        start_time=now - 10,  # Already active
        end_time=now + 3600,
        required_cpu=0.8,
        required_memory_mb=512,
        priority=50,
    )
    
    # Mark reservation as fulfilled (resources reserved)
    res.fulfilled = True
    
    # Check available capacity with reservations
    capacity = sched.get_available_capacity_with_reservations()
    
    assert capacity["available_cpu"] < 0.3, f"CPU should be reserved: {capacity['available_cpu']}"
    assert capacity["available_memory_mb"] < 600, f"Memory should be reserved: {capacity['available_memory_mb']}"
    
    # Try to admit a workload that would exceed remaining capacity
    limits = ResourceLimits(cpus=0.5, memory_mb=128, gpu_count=0)
    result = sched.admit(
        workload_id="contending-wl",
        required=limits,
        priority=50,
        mode=QueueMode.NORMAL,
        is_interactive=False,
    )
    
    # Should be rejected due to reservation consumption (only 0.2 CPU left)
    assert not result.granted, "Should reject: insufficient capacity due to reservation"
    
    print("PASS: J19-2_reservations_block_capacity")


def test_reservation_cancel():
    """J19-2b: Reservations can be cancelled."""
    sched = Scheduler()
    now = time.time()
    
    res = sched.create_reservation(
        workload_id="cancel-wl",
        user_id="dave",
        start_time=now,
        end_time=now + 3600,
        required_cpu=0.5,
    )
    
    # Cancel the reservation
    cancelled = sched.cancel_reservation(res.reservation_id)
    assert cancelled, "Reservation should be cancellable"
    assert res.cancelled, "Reservation object should reflect cancellation"
    
    print("PASS: J19-2b_reservation_cancel")


def test_preemption():
    """J19-3: Preemption frees resources for higher-priority workloads.
    
    Verifies that lower-priority workloads can be preempted to admit
    high-priority requests.
    """
    sched = Scheduler()
    # Set capacity with only 1 CPU total
    sched.state.total_cpu = 1.0
    sched.state.total_memory_mb = 2048
    sched.state.total_gpu = 0
    
    now = time.time()
    
    # Admit a low-priority workload (fills all CPU)
    low_limits = ResourceLimits(cpus=0.9, memory_mb=512, gpu_count=0)
    result = sched.admit(
        workload_id="low-pri-wl",
        required=low_limits,
        priority=20,  # Low priority
        mode=QueueMode.NORMAL,
        is_interactive=False,
    )
    assert result.granted, "Low priority should be admitted initially"
    
    # Try to admit a high-priority workload that needs more CPU
    high_limits = ResourceLimits(cpus=0.9, memory_mb=512, gpu_count=0)
    preempted = sched.preempt_if_needed(
        high_priority_id="high-pri-wl",
        required=high_limits,
        minimum_priority=80,  # Only preempt if priority < 80
    )
    
    assert "low-pri-wl" in preempted, f"Low-priority workload should be preempted: {preempted}"
    
    # Now the high-priority workload should be admitable (we could call admit here)
    assert sched.state.allocated_cpu < 0.2, f"CPU should be freed after preemption: {sched.state.allocated_cpu}"
    
    print("PASS: J19-3_preemption")


def test_anti_loop_detection():
    """J19-4: Cycle detection prevents circular dependencies in multi-agent trees (§5.4)."""
    sched = Scheduler()
    
    # Build a valid tree: A → B → C (no cycle)
    assert sched.add_dependency("B", "A"), "B depends on A"
    assert sched.add_dependency("C", "B"), "C depends on B"
    
    # Try to create a cycle: A → B → C → A should fail
    has_cycle = not sched.is_acyclic("A", "C")  # Would create A←C (cycle)
    assert has_cycle, "Adding A→C should detect cycle in A←B←C tree"
    
    # Self-reference should also be rejected
    assert not sched.add_dependency("self-test", "self-test"), "Self-reference is a cycle"
    
    # Check for cycles directly
    cycles = sched.detect_cycles()
    # Should have no cycles since we haven't added the back-edge
    assert len(cycles) == 0, f"Expected no cycles yet: {cycles}"
    
    # Now add the back-edge and verify cycle is detected
    sched.state.cycle_tracker["A"] = {"C"}  # Manually add A←C to create cycle
    cycles = sched.detect_cycles()
    assert len(cycles) > 0, "Should detect cycle after adding back-edge"
    
    print("PASS: J19-4_anti_loop_detection")


def test_orphan_detection():
    """J19-5: Orphan workload detection and draining."""
    sched = Scheduler()
    now = time.time()
    
    # Set sufficient capacity for both parent and child
    sched.state.total_cpu = 2.0
    sched.state.total_memory_mb = 2048
    
    # Admit a parent workload
    parent_limits = ResourceLimits(cpus=0.5, memory_mb=256, gpu_count=0)
    result_parent = sched.admit(
        workload_id="parent-wl",
        required=parent_limits,
        priority=50,
        mode=QueueMode.NORMAL,
        is_interactive=False,
    )
    assert result_parent.granted, f"Parent should be admitted: {result_parent.reason}"
    
    # Admit a child with parent_id
    child_limits = ResourceLimits(cpus=0.5, memory_mb=256, gpu_count=0)
    result_child = sched.admit(
        workload_id="child-wl",
        required=child_limits,
        priority=50,
        mode=QueueMode.NORMAL,
        is_interactive=False,
    )
    assert result_child.granted, f"Child should be admitted: {result_child.reason}"
    
    # Manually set parent_id on child to simulate multi-agent relationship
    sched.state.active_workloads["child-wl"]["parent_id"] = "parent-wl"
    
    # Child should not be orphan yet (parent exists)
    orphans = sched.get_orphan_workloads()
    assert "child-wl" not in orphans, "Child should not be orphan while parent is active"
    
    # Release parent
    sched.release("parent-wl")
    
    # Child is now an orphan
    orphans = sched.get_orphan_workloads()
    assert "child-wl" in orphans, f"Child should be orphan: {orphans}"
    
    # Drain with generous grace period (immediate for test)
    drained = sched.drain_orphans(grace_seconds=0)
    assert "child-wl" in drained, "Orphan should be drained"
    
    print("PASS: J19-5_orphan_detection")


def test_multi_agent_aggregation():
    """J19-6: Multi-agent tree aggregation respects hierarchy limits."""
    sched = Scheduler()
    # Set total capacity
    sched.state.total_cpu = 4.0
    
    # Simulate parent with children using _aggregate_parent_children
    result = sched._aggregate_parent_children(
        parent_id="parent-x",
        child_required=ResourceLimits(cpus=1.0, memory_mb=512, gpu_count=0),
    )
    
    assert result["allowed"], "Small child should be allowed"
    assert "aggregated" in result
    
    # Now simulate children exceeding 90% of total CPU
    # Add workload as if it's a child of parent-x
    sched.state.active_workloads["child1"] = {
        "required": ResourceLimits(cpus=2.0, memory_mb=512, gpu_count=0),
        "parent_id": "parent-x",
    }
    
    result2 = sched._aggregate_parent_children(
        parent_id="parent-x",
        child_required=ResourceLimits(cpus=2.0, memory_mb=512, gpu_count=0),  # Would push to 4.0 total
    )
    
    # Should be rejected (>90% of 4.0 = 3.6, and we'd have ~4.0)
    assert not result2["allowed"], "Parent tree exceeding 90% should be rejected"
    
    print("PASS: J19-6_multi_agent_aggregation")


def test_scheduler_event_log():
    """J19-7: Scheduler emits events for audit trail."""
    sched = Scheduler()
    now = time.time()
    
    # Create reservation and verify event is logged
    res = sched.create_reservation(
        workload_id="event-wl",
        user_id="eve",
        start_time=now,
        end_time=now + 3600,
    )
    
    assert len(sched.state.event_log) > 0, "Event log should not be empty"
    last_event = sched.state.event_log[-1]
    assert last_event.event_type == SchedulerEvent.RESERVATION_CREATED
    assert last_event.workload_id == "event-wl"
    
    # Cancel and verify event
    sched.cancel_reservation(res.reservation_id)
    
    assert len(sched.state.event_log) > 0, "Event log should grow with cancellations"
    last_event = sched.state.event_log[-1]
    assert last_event.event_type == SchedulerEvent.RESERVATION_EXPIRED
    
    print("PASS: J19-7_scheduler_event_log")


if __name__ == "__main__":
    test_calendar_admission()
    test_reservations_block_capacity()
    test_reservation_cancel()
    test_preemption()
    test_anti_loop_detection()
    test_orphan_detection()
    test_multi_agent_aggregation()
    test_scheduler_event_log()
    print("\n=== J19_scheduler_advanced passed ===")
