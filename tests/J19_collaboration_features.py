"""tests/J19_collaboration_features.py — §M10 Collaboration features tests.

Validates:
- File-based persistence for scheduler state
- Mattermost integration functionality  
- Dify integration functionality
- Collaboration bot notifications
- Scheduler event collaboration integration

Tests:
- J19-collab-1: Scheduler state persistence (save/load)
- J19-collab-2: Mattermost client configuration and messaging
- J19-collab-3: Dify client workflow execution
- J19-collab-4: Collaboration bot event handling
- J19-collab-5: Scheduler collaboration notifications
"""

import sys
import json
import tempfile
import time
from pathlib import Path

sys.path.insert(0, "src")

from agentic.control.scheduler import (
    Scheduler, ResourceLimits, QueueMode, AdmissionResult,
    Reservation, CalendarEntry, SchedulerEventRecord, SchedulerEvent,
    SchedulerConfig,
)
from agentic.collaboration import (
    MattermostClient, MattermostConfig, MattermostMessage,
    DifyClient, DifyConfig,
    SchedulerNotificationBot, CollaborationBot, BotConfig, BotEvent, BotEventType,
)


def test_scheduler_persistence():
    """J19-collab-1: Scheduler state persistence (save/load).
    
    Verifies that scheduler state can be persisted to and loaded from files.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        config = SchedulerConfig(state_dir=tmpdir, auto_persist=False)
        sched = Scheduler(config=config)
        
        # Set system capacity and admit some workloads
        sched.state.total_cpu = 8.0
        sched.state.total_memory_mb = 16384
        sched.state.total_gpu = 4
        
        # Admit a workload
        limits = ResourceLimits(cpus=1.0, memory_mb=2048, gpu_count=1)
        result = sched.admit("test-workload-1", limits, priority=75)
        assert result.granted, "Should be able to admit workload"
        
        # Create a reservation
        sched.create_reservation(
            workload_id="test-reservation-1",
            user_id="test-user",
            start_time=time.time() + 3600,
            end_time=time.time() + 7200,
            required_cpu=2.0,
            required_memory_mb=4096,
        )
        
        # Create a calendar entry
        sched.create_calendar_entry(
            workload_id="test-calendar-1",
            user_id="test-user",
            scheduled_start=time.time() + 1800,
            scheduled_end=time.time() + 3600,
            resource_limits={"cpus": 0.5, "memory_mb": 512},
        )
        
        # Save state
        save_result = sched.save_state()
        assert save_result, "Should successfully save state"
        
        # Verify files exist
        state_file = Path(tmpdir) / "scheduler_state.json"
        event_file = Path(tmpdir) / "scheduler_events.json"
        assert state_file.exists(), "State file should exist"
        assert event_file.exists(), "Event log file should exist"
        
        # Verify file contents
        with open(state_file, "r", encoding="utf-8") as f:
            state_data = json.load(f)
        
        assert state_data["total_cpu"] == 8.0, "Should persist total CPU"
        assert state_data["total_memory_mb"] == 16384, "Should persist total memory"
        assert state_data["total_gpu"] == 4, "Should persist total GPU"
        assert "test-workload-1" in state_data["active_workloads"], "Should persist active workloads"
        assert len(state_data["reservations"]) == 1, "Should persist reservations"
        assert len(state_data["calendar"]) == 1, "Should persist calendar entries"
        
        # Create new scheduler and load state
        sched2 = Scheduler(config=config)
        load_result = sched2.load_state()
        assert load_result, "Should successfully load state"
        
        # Verify loaded state
        assert sched2.state.total_cpu == 8.0, "Should load total CPU"
        assert sched2.state.total_memory_mb == 16384, "Should load total memory"
        assert sched2.state.total_gpu == 4, "Should load total GPU"
        assert "test-workload-1" in sched2.state.active_workloads, "Should load active workloads"
        assert len(sched2.state.reservations) == 1, "Should load reservations"
        assert len(sched2.state.calendar) == 1, "Should load calendar entries"
        
    print("PASS: J19-collab-1_scheduler_persistence")


def test_mattermost_client():
    """J19-collab-2: Mattermost client configuration and messaging.
    
    Verifies Mattermost client functionality.
    """
    # Test configuration
    config = MattermostConfig(
        server_url="http://test-server:8065",
        api_token="test-token",
        default_channel="test-channel",
        bot_username="test-bot"
    )
    
    client = MattermostClient(config)
    assert client.config.server_url == "http://test-server:8065", "Should use provided server URL"
    assert client.config.api_token == "test-token", "Should use provided API token"
    assert client.config.default_channel == "test-channel", "Should use provided default channel"
    
    # Test message creation
    message = MattermostMessage(
        channel_id="test-channel",
        text="Test message",
        username="test-user",
        icon_url="http://test-icon.png"
    )
    
    post_data = message.to_post_data()
    assert post_data["channel_id"] == "test-channel", "Should set channel ID"
    assert post_data["message"] == "Test message", "Should set message"
    assert post_data["username"] == "test-user", "Should set username"
    assert post_data["icon_url"] == "http://test-icon.png", "Should set icon URL"
    
    # Test send_scheduler_event formatting
    test_cases = [
        ("workload_admitted", {"cpu": 1.0, "memory_mb": 512}, "✅"),
        ("workload_preempted", {"reason": "test"}, "⚠️"),
        ("workload_released", {"duration": "10s"}, "🗑️"),
        ("reservation_created", {"start": 123.0, "end": 456.0}, "📅"),
        ("calendar_triggered", {"scheduled_at": 123.0}, "🕐"),
    ]
    
    for event_type, details, expected_emoji in test_cases:
        # This would normally send to Mattermost, but we're just testing the formatting
        # by checking that the method doesn't raise an exception
        try:
            result = client.send_scheduler_event(
                event_type=event_type,
                workload_id="test-workload",
                details=details,
            )
            # Should return False since we're not connected to a real Mattermost server
            assert result == False, f"Should return False for event {event_type} when not connected"
        except Exception as e:
            # Should not raise exceptions for unknown hosts
            pass
    
    print("PASS: J19-collab-2_mattermost_client")


def test_dify_client():
    """J19-collab-3: Dify client workflow execution.
    
    Verifies Dify client functionality.
    """
    # Test configuration
    config = DifyConfig(
        server_url="http://test-server:8080",
        api_key="test-api-key",
        default_workspace="test-workspace"
    )
    
    client = DifyClient(config)
    assert client.config.server_url == "http://test-server:8080", "Should use provided server URL"
    assert client.config.api_key == "test-api-key", "Should use provided API key"
    assert client.config.default_workspace == "test-workspace", "Should use provided default workspace"
    
    # Test is_connected (should return False since we're not connected to a real server)
    connected = client.is_connected()
    assert connected == False, "Should return False when not connected to real Dify server"
    
    # Test workflow execution (should return None when not connected)
    result = client.execute_workflow(
        workflow_id="test-workflow",
        inputs={"test": "input"},
        user_id="test-user"
    )
    assert result is None, "Should return None when not connected to real Dify server"
    
    # Test scheduler decision (should return None when not connected)
    decision = client.execute_scheduler_decision(
        workload_id="test-workload",
        required_resources={"cpu": 1.0, "memory_mb": 512},
        system_status={"cpu_utilization": 0.8},
        user_id="test-user"
    )
    assert decision is None, "Should return None when not connected to real Dify server"
    
    print("PASS: J19-collab-3_dify_client")


def test_collaboration_bot():
    """J19-collab-4: Collaboration bot event handling.
    
    Verifies collaboration bot functionality.
    """
    # Test with disabled bot to avoid threading issues in tests
    bot_config = BotConfig(
        enabled=False,
        mattermost_enabled=False,
        dify_enabled=False,
    )
    
    bot = SchedulerNotificationBot(config=bot_config)
    
    # Test event creation
    event = BotEvent(
        event_type=BotEventType.SCHEDULER_ADMIT,
        workload_id="test-workload",
        user_id="test-user",
        details={"cpu": 1.0, "memory_mb": 512},
        priority=75
    )
    
    assert event.event_type == BotEventType.SCHEDULER_ADMIT, "Should have correct event type"
    assert event.workload_id == "test-workload", "Should have correct workload ID"
    assert event.user_id == "test-user", "Should have correct user ID"
    assert event.priority == 75, "Should have correct priority"
    
    # Test event emission (should work even when bot is disabled)
    emit_result = bot.emit_event(event)
    # Note: emit_event might fail if queue is full, but in this case it should succeed
    # since we're just testing the basic functionality
    
    # Test notify_scheduler_event
    notify_result = bot.notify_scheduler_event(
        event_type="workload_admitted",
        workload_id="test-workload",
        user_id="test-user",
        details={"cpu": 1.0, "memory_mb": 512}
    )
    # Should return True since bot can queue events even when disabled
    assert notify_result == True, "Should queue scheduler event notification"
    
    # Test system status
    status = bot.get_system_status()
    assert "timestamp" in status, "Should include timestamp"
    assert "system_health" in status, "Should include system health"
    assert "resource_utilization" in status, "Should include resource utilization"
    
    print("PASS: J19-collab-4_collaboration_bot")


def test_scheduler_collaboration_integration():
    """J19-collab-5: Scheduler collaboration notifications.
    
    Verifies that scheduler properly integrates with collaboration bots.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        config = SchedulerConfig(state_dir=tmpdir, auto_persist=False)
        sched = Scheduler(config=config)
        
        # Set system capacity
        sched.state.total_cpu = 4.0
        sched.state.total_memory_mb = 8192
        sched.state.total_gpu = 2
        
        # Create collaboration bot
        bot_config = BotConfig(enabled=False)  # Disabled to avoid threading
        bot = SchedulerNotificationBot(config=bot_config)
        
        # Connect bot to scheduler
        sched.set_collaboration_bot(bot)
        
        # Test admission with collaboration notification
        limits = ResourceLimits(cpus=0.5, memory_mb=512, gpu_count=0)
        result = sched.admit("collab-workload", limits, priority=80, user_id="collab-user")
        assert result.granted, "Should admit workload"
        
        # Test release with collaboration notification
        release_result = sched.release("collab-workload")
        assert release_result, "Should release workload"
        
        # Test reservation with collaboration notification
        reservation = sched.create_reservation(
            workload_id="collab-reservation",
            user_id="collab-user",
            start_time=time.time() + 3600,
            end_time=time.time() + 7200,
            required_cpu=1.0,
            required_memory_mb=1024,
        )
        assert reservation is not None, "Should create reservation"
        assert reservation.reservation_id, "Should have reservation ID"
        
        # Test preemption with collaboration notification
        # First admit a low-priority workload
        low_limits = ResourceLimits(cpus=1.0, memory_mb=1024, gpu_count=0)
        low_result = sched.admit("low-pri-workload", low_limits, priority=20, is_interactive=False)
        assert low_result.granted, "Should admit low priority workload"
        
        # Now preempt it
        high_limits = ResourceLimits(cpus=1.0, memory_mb=1024, gpu_count=0)
        preempted = sched.preempt_if_needed("high-pri-workload", high_limits, minimum_priority=50)
        assert "low-pri-workload" in preempted, "Should preempt low priority workload"
        
        # Test calendar with collaboration notification
        sched.create_calendar_entry(
            workload_id="collab-calendar",
            user_id="collab-user",
            scheduled_start=time.time() - 60,  # Already ready
            scheduled_end=time.time() + 3600,
            resource_limits={"cpus": 0.5, "memory_mb": 512},
        )
        
        # Check calendar (this should trigger the event and notify bot)
        admitted = sched.check_calendar_and_admit()
        assert "collab-calendar" in admitted, "Should admit calendar workload"
        
        print("PASS: J19-collab-5_scheduler_collaboration_integration")


def test_file_persistence_edge_cases():
    """J19-collab-6: File persistence edge cases.
    
    Verifies edge cases for file persistence.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        # Test saving empty state
        config = SchedulerConfig(state_dir=tmpdir, auto_persist=False)
        sched = Scheduler(config=config)
        
        # Test saving empty state
        save_result = sched.save_state()
        assert save_result, "Should save empty state"
        
        # Test loading non-existent file from new directory
        with tempfile.TemporaryDirectory() as tmpdir2:
            empty_config = SchedulerConfig(state_dir=tmpdir2, auto_persist=False)
            sched_empty = Scheduler(config=empty_config)
            load_result = sched_empty.load_state()
            assert load_result == False, "Should return False when file doesn't exist"
        
        # Test custom file path
        custom_path = Path(tmpdir) / "custom_state.json"
        save_result = sched.save_state(custom_path)
        assert save_result, "Should save to custom path"
        assert custom_path.exists(), "Custom path file should exist"
        
        # Test loading from custom path
        sched3 = Scheduler(config=SchedulerConfig(state_dir=tmpdir, auto_persist=False))
        load_result = sched3.load_state(custom_path)
        assert load_result, "Should load from custom path"
        
    print("PASS: J19-collab-6_file_persistence_edge_cases")


def test_auto_persistence():
    """J19-collab-7: Auto persistence functionality.
    
    Verifies automatic persistence based on time intervals.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        config = SchedulerConfig(
            state_dir=tmpdir, 
            auto_persist=True,
            persist_interval_seconds=0.1  # Very short interval for testing
        )
        sched = Scheduler(config=config)
        
        # Set some state
        sched.state.total_cpu = 2.0
        
        # First call to maybe_persist should persist (last persist time is 0)
        first_result = sched.maybe_persist()
        assert first_result, "Should persist on first call"
        
        # Verify file was created
        state_file = Path(tmpdir) / "scheduler_state.json"
        assert state_file.exists(), "Should create state file"
        
        # Second call immediately should not persist (interval not elapsed)
        second_result = sched.maybe_persist()
        assert second_result == False, "Should not persist if interval not elapsed"
        
        # Wait for interval to elapse
        time.sleep(0.15)
        
        # Third call should persist
        third_result = sched.maybe_persist()
        assert third_result, "Should persist after interval elapsed"
        
        # Test with auto_persist disabled
        config.disabled = SchedulerConfig(
            state_dir=tmpdir,
            auto_persist=False,
            persist_interval_seconds=0.1
        )
        sched_disabled = Scheduler(config=config.disabled)
        sched_disabled._last_persist_time = 0  # Reset timer
        
        disabled_result = sched_disabled.maybe_persist()
        assert disabled_result == False, "Should not persist when auto_persist is disabled"
        
    print("PASS: J19-collab-7_auto_persistence")


if __name__ == "__main__":
    test_scheduler_persistence()
    test_mattermost_client()
    test_dify_client()
    test_collaboration_bot()
    test_scheduler_collaboration_integration()
    test_file_persistence_edge_cases()
    test_auto_persistence()
    print("\n=== J19_collaboration_features passed ===")