"""src/agentic/collaboration/ — Collaboration integrations for M10 (§M10).

This module provides:
- Mattermost integration for team collaboration
- Dify integration for AI workflow collaboration
- Collaboration bots for scheduler notifications
- Webhook-based event handling
"""

from .mattermost_client import MattermostClient, MattermostConfig, MattermostMessage
from .dify_client import DifyClient, DifyConfig, DifyWorkflow
from .collaboration_bot import CollaborationBot, SchedulerNotificationBot, BotConfig, BotEvent, BotEventType

__all__ = [
    "MattermostClient",
    "MattermostConfig", 
    "MattermostMessage",
    "DifyClient",
    "DifyConfig",
    "DifyWorkflow",
    "CollaborationBot",
    "SchedulerNotificationBot",
    "BotConfig",
    "BotEvent",
    "BotEventType",
]