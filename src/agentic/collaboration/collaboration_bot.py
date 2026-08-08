"""src/agentic/collaboration/collaboration_bot.py — Collaboration bots for scheduler (§M10)."""

from __future__ import annotations

import json
import logging
import queue
import threading
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Optional

from .mattermost_client import MattermostClient, MattermostConfig
from .dify_client import DifyClient, DifyConfig

logger = logging.getLogger(__name__)


class BotEventType(Enum):
    """Types of collaboration bot events (§M10)."""
    SCHEDULER_ADMIT = "scheduler.admit"
    SCHEDULER_RELEASE = "scheduler.release"
    SCHEDULER_PREEMPT = "scheduler.preempt"
    SCHEDULER_RESERVATION = "scheduler.reservation"
    SCHEDULER_CALENDAR = "scheduler.calendar"
    SYSTEM_ALERT = "system.alert"
    COLLABORATION_REQUEST = "collaboration.request"
    DECISION_REQUEST = "decision.request"


@dataclass
class BotEvent:
    """Event for collaboration bot processing (§M10)."""
    event_type: BotEventType
    workload_id: str = ""
    user_id: str = ""
    details: dict[str, Any] = field(default_factory=dict)
    timestamp: float = field(default_factory=time.time)
    priority: int = 50


@dataclass
class BotConfig:
    """Configuration for collaboration bots (§M10)."""
    bot_name: str = "agentic-scheduler-bot"
    enabled: bool = True
    mattermost_enabled: bool = True
    dify_enabled: bool = True
    notification_level: str = "normal"  # "minimal", "normal", "verbose"
    max_queue_size: int = 1000
    worker_count: int = 2


class CollaborationBot:
    """Base class for collaboration bots (§M10).
    
    Provides common functionality for bots that handle collaboration events
    and integrate with external platforms like Mattermost and Dify.
    """

    def __init__(self, config: BotConfig | None = None):
        """Initialize collaboration bot.
        
        Args:
            config: Bot configuration. Uses defaults if None.
        """
        self.config = config or BotConfig()
        self._event_queue: queue.Queue[BotEvent] = queue.Queue()
        self._running: bool = False
        self._workers: list[threading.Thread] = []
        self._handlers: dict[BotEventType, list[Callable]] = {}
        
        # Initialize platform clients
        self.mattermost_client: MattermostClient | None = None
        self.dify_client: DifyClient | None = None
        
        if self.config.mattermost_enabled:
            self.mattermost_client = MattermostClient()
        if self.config.dify_enabled:
            self.dify_client = DifyClient()

    def start(self) -> None:
        """Start the bot's event processing workers (§M10)."""
        if not self.config.enabled:
            logger.info("Bot is disabled, not starting")
            return
            
        self._running = True
        for i in range(self.config.worker_count):
            worker = threading.Thread(
                target=self._worker_loop,
                name=f"{self.config.bot_name}-worker-{i}",
                daemon=True,
            )
            worker.start()
            self._workers.append(worker)
        
        logger.info(f"Started {self.config.worker_count} workers for {self.config.bot_name}")

    def stop(self) -> None:
        """Stop the bot's event processing (§M10)."""
        self._running = False
        
        # Add a poison pill for each worker to ensure they exit
        for _ in range(len(self._workers)):
            try:
                self._event_queue.put_nowait(BotEvent(
                    event_type=BotEventType.SYSTEM_ALERT,
                    details={"command": "shutdown"}
                ))
            except queue.Full:
                pass
        
        # Wait for workers to finish
        for worker in self._workers:
            worker.join(timeout=5.0)
        
        self._workers.clear()
        logger.info(f"Stopped {self.config.bot_name}")

    def _worker_loop(self) -> None:
        """Worker thread main loop (§M10)."""
        while self._running:
            try:
                event = self._event_queue.get(timeout=1.0)
                self._process_event(event)
                self._event_queue.task_done()
            except queue.Empty:
                continue
            except Exception as e:
                logger.error(f"Error processing event in worker: {e}")

    def _process_event(self, event: BotEvent) -> None:
        """Process a bot event (§M10)."""
        if event.event_type == BotEventType.SYSTEM_ALERT and \
           event.details.get("command") == "shutdown":
            return  # Shutdown signal
        
        # Call registered handlers
        handlers = self._handlers.get(event.event_type, [])
        for handler in handlers:
            try:
                handler(event)
            except Exception as e:
                logger.error(f"Handler error for {event.event_type}: {e}")
        
        # Default processing
        self._default_process_event(event)

    def _default_process_event(self, event: BotEvent) -> None:
        """Default event processing logic (§M10)."""
        # This can be overridden by subclasses
        pass

    def on(self, event_type: BotEventType) -> Callable:
        """Decorator to register event handlers (§M10)."""
        def decorator(func: Callable[[BotEvent], None]) -> Callable[[BotEvent], None]:
            if event_type not in self._handlers:
                self._handlers[event_type] = []
            self._handlers[event_type].append(func)
            return func
        return decorator

    def emit_event(self, event: BotEvent) -> bool:
        """Emit an event to the bot for processing (§M10).
        
        Args:
            event: The event to process
            
        Returns:
            True if event was queued successfully, False if queue is full.
        """
        try:
            self._event_queue.put_nowait(event)
            return True
        except queue.Full:
            logger.warning(f"Event queue full, dropping event: {event.event_type}")
            return False

    def send_notification(
        self, 
        message: str, 
        channel: str = "agentic-scheduler",
        details: dict[str, Any] | None = None,
    ) -> bool:
        """Send a notification via Mattermost if available (§M10)."""
        if not self.mattermost_client:
            return False
        
        return self.mattermost_client.send_notification(
            channel=channel,
            text=message,
            username=self.config.bot_name,
        )

    def execute_ai_decision(
        self,
        prompt: str,
        context: dict[str, Any],
        workflow_id: str | None = None,
    ) -> dict[str, Any] | None:
        """Execute an AI decision via Dify if available (§M10)."""
        if not self.dify_client:
            return None
        
        return self.dify_client.send_collaboration_prompt(
            prompt=prompt,
            context=context,
            workflow_id=workflow_id,
        )


class SchedulerNotificationBot(CollaborationBot):
    """Specialized bot for scheduler notifications and collaboration (§M10).
    
    Handles:
    - Scheduler event notifications
    - Resource allocation decisions
    - Collaboration workflows
    - Multi-agent coordination
    """

    def __init__(self, config: BotConfig | None = None):
        """Initialize scheduler notification bot."""
        super().__init__(config or BotConfig(bot_name="scheduler-bot"))
        
        # Register default handlers
        self.on(BotEventType.SCHEDULER_ADMIT)(self._handle_scheduler_admit)
        self.on(BotEventType.SCHEDULER_RELEASE)(self._handle_scheduler_release)
        self.on(BotEventType.SCHEDULER_PREEMPT)(self._handle_scheduler_preempt)
        self.on(BotEventType.SCHEDULER_RESERVATION)(self._handle_scheduler_reservation)
        self.on(BotEventType.SCHEDULER_CALENDAR)(self._handle_scheduler_calendar)

    def _handle_scheduler_admit(self, event: BotEvent) -> None:
        """Handle scheduler admit events (§M10)."""
        message = f"✅ Workload Admitted: `{event.workload_id}`"
        if event.details:
            cpu = event.details.get("cpu", 0)
            memory = event.details.get("memory_mb", 0)
            gpu = event.details.get("gpu", 0)
            priority = event.details.get("priority", "normal")
            message += f"\n📊 Resources: CPU={cpu}, Memory={memory}MB, GPU={gpu}"
            message += f"\n🎯 Priority: {priority}"
            message += f"\n👤 User: {event.user_id}"
        
        self.send_notification(message, "agentic-scheduler")
        
        # For high-priority admissions, also log to Dify for decision tracking
        if event.priority >= 80:
            context = {
                "event_type": "admit",
                "workload_id": event.workload_id,
                "user_id": event.user_id,
                "resources": event.details,
            }
            self.execute_ai_decision(
                prompt=f"High priority workload {event.workload_id} admitted. "
                      f"Review resource allocation: {json.dumps(event.details)}",
                context=context,
                workflow_id="scheduler-monitoring"
            )

    def _handle_scheduler_release(self, event: BotEvent) -> None:
        """Handle scheduler release events (§M10)."""
        message = f"🗑️ Workload Released: `{event.workload_id}`"
        if event.details:
            duration = event.details.get("duration", "unknown")
            message += f"\n⏱️ Duration: {duration}"
            message += f"\n👤 User: {event.user_id}"
        
        self.send_notification(message, "agentic-scheduler")

    def _handle_scheduler_preempt(self, event: BotEvent) -> None:
        """Handle scheduler preempt events (§M10)."""
        message = f"⚠️ Workload Preempted: `{event.workload_id}`"
        if event.details:
            reason = event.details.get("reason", "priority preemption")
            preempted_by = event.details.get("preempted_by", "unknown")
            message += f"\n💥 Reason: {reason}"
            message += f"\n🎯 Preempted by: {preempted_by}"
            message += f"\n👤 User: {event.user_id}"
        
        self.send_notification(message, "agentic-scheduler")
        
        # Always log preemptions to Dify for analysis
        context = {
            "event_type": "preempt",
            "workload_id": event.workload_id,
            "user_id": event.user_id,
            "details": event.details,
        }
        self.execute_ai_decision(
            prompt=f"Workload {event.workload_id} was preempted. "
                  f"Analyze impact and suggest improvements: {json.dumps(event.details)}",
            context=context,
            workflow_id="scheduler-optimization"
        )

    def _handle_scheduler_reservation(self, event: BotEvent) -> None:
        """Handle scheduler reservation events (§M10)."""
        message = f"📅 Reservation: `{event.workload_id}`"
        if event.details:
            start = event.details.get("start", "unknown")
            end = event.details.get("end", "unknown")
            resources = event.details.get("resources", {})
            message += f"\n🕒 Start: {start}"
            message += f"\n🕓 End: {end}"
            message += f"\n📊 Resources: {json.dumps(resources)}"
            message += f"\n👤 User: {event.user_id}"
        
        self.send_notification(message, "agentic-scheduler")

    def _handle_scheduler_calendar(self, event: BotEvent) -> None:
        """Handle scheduler calendar events (§M10)."""
        message = f"🕐 Calendar Event: `{event.workload_id}`"
        if event.details:
            scheduled_at = event.details.get("scheduled_at", "unknown")
            status = event.details.get("status", "triggered")
            message += f"\n📅 Scheduled: {scheduled_at}"
            message += f"\n📊 Status: {status}"
            message += f"\n👤 User: {event.user_id}"
        
        self.send_notification(message, "agentic-scheduler")

    def notify_scheduler_event(
        self,
        event_type: str,
        workload_id: str,
        user_id: str = "",
        details: dict[str, Any] | None = None,
    ) -> bool:
        """Notify about a scheduler event (§M10).
        
        Args:
            event_type: Scheduler event type (from SchedulerEvent enum)
            workload_id: ID of the workload
            user_id: User who owns the workload
            details: Additional event details
            
        Returns:
            True if notification was queued successfully.
        """
        # Map scheduler event types to bot event types
        event_mapping = {
            "workload_admitted": BotEventType.SCHEDULER_ADMIT,
            "workload_dequeued": BotEventType.SCHEDULER_ADMIT,
            "workload_preempted": BotEventType.SCHEDULER_PREEMPT,
            "workload_released": BotEventType.SCHEDULER_RELEASE,
            "reservation_created": BotEventType.SCHEDULER_RESERVATION,
            "reservation_fulfilled": BotEventType.SCHEDULER_RESERVATION,
            "reservation_expired": BotEventType.SCHEDULER_RESERVATION,
            "calendar_triggered": BotEventType.SCHEDULER_CALENDAR,
        }
        
        bot_event_type = event_mapping.get(event_type, BotEventType.SYSTEM_ALERT)
        
        event = BotEvent(
            event_type=bot_event_type,
            workload_id=workload_id,
            user_id=user_id,
            details=details or {},
            priority=80 if event_type == "workload_preempted" else 50,
        )
        
        return self.emit_event(event)

    def get_system_status(self) -> dict[str, Any]:
        """Get current system status for AI decision making (§M10)."""
        # This would be populated with actual system metrics in production
        return {
            "timestamp": time.time(),
            "system_health": "normal",
            "resource_utilization": {
                "cpu": 0.7,
                "memory": 0.6,
                "gpu": 0.8,
            },
            "active_workloads": 0,
            "queued_workloads": 0,
            "recent_events": [],
        }