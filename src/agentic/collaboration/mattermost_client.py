"""src/agentic/collaboration/mattermost_client.py — Mattermost integration for collaboration (§M10)."""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Optional

import requests

logger = logging.getLogger(__name__)


@dataclass
class MattermostConfig:
    """Configuration for Mattermost integration (§M10)."""
    server_url: str = "http://127.0.0.1:8065"
    api_token: str = ""
    default_channel: str = "agentic-scheduler"
    bot_username: str = "agentic-bot"
    bot_display_name: str = "Agentic Scheduler Bot"
    timeout_seconds: int = 30
    retry_count: int = 3
    retry_delay: float = 1.0


@dataclass
class MattermostMessage:
    """Structured message for Mattermost (§M10)."""
    channel_id: str = ""
    text: str = ""
    username: str = ""
    icon_url: str = ""
    props: dict[str, Any] = field(default_factory=dict)
    
    def to_post_data(self) -> dict[str, Any]:
        """Convert to Mattermost post data format."""
        post_data = {
            "channel_id": self.channel_id,
            "message": self.text,
        }
        if self.username:
            post_data["username"] = self.username
        if self.icon_url:
            post_data["icon_url"] = self.icon_url
        if self.props:
            post_data["props"] = self.props
        return post_data


class MattermostClient:
    """Client for Mattermost collaboration platform (§M10).
    
    Provides integration with Mattermost for:
    - Posting scheduler notifications
    - Creating and managing posts
    - Team collaboration messaging
    """

    def __init__(self, config: MattermostConfig | None = None):
        """Initialize Mattermost client.
        
        Args:
            config: Mattermost configuration. Uses defaults if None.
        """
        self.config = config or MattermostConfig()
        self._session = requests.Session()
        self._session.headers.update({
            "Authorization": f"Bearer {self.config.api_token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        })
        self._channel_cache: dict[str, str] = {}  # channel_name -> channel_id

    def _make_request(
        self, 
        method: str, 
        endpoint: str, 
        data: dict[str, Any] | None = None,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any] | list[dict[str, Any]] | None:
        """Make HTTP request to Mattermost API with retry logic."""
        url = f"{self.config.server_url}/api/v4/{endpoint}"
        
        for attempt in range(self.config.retry_count):
            try:
                response = self._session.request(
                    method,
                    url,
                    json=data,
                    params=params,
                    timeout=self.config.timeout_seconds,
                )
                
                if response.status_code == 200:
                    try:
                        return response.json()
                    except ValueError:
                        return None
                elif response.status_code == 201:  # Created
                    try:
                        return response.json()
                    except ValueError:
                        return None
                elif response.status_code == 401:
                    logger.error("Mattermost authentication failed")
                    return None
                elif response.status_code == 404:
                    logger.debug(f"Mattermost endpoint not found: {endpoint}")
                    return None
                else:
                    logger.warning(f"Mattermost API error {response.status_code}: {response.text}")
                    
            except requests.RequestException as e:
                logger.warning(f"Mattermost request failed (attempt {attempt + 1}): {e}")
                if attempt < self.config.retry_count - 1:
                    time.sleep(self.config.retry_delay * (attempt + 1))
                    continue
                else:
                    logger.error(f"Mattermost request failed after all retries: {e}")
                    return None
        
        return None

    def get_channel_id(self, channel_name: str) -> str | None:
        """Get channel ID by name, with caching (§M10)."""
        if channel_name in self._channel_cache:
            return self._channel_cache[channel_name]
        
        # Try to get channel by name
        result = self._make_request("GET", f"channels/name/{channel_name}")
        if result and isinstance(result, dict) and result.get("id"):
            self._channel_cache[channel_name] = result["id"]
            return result["id"]
        
        return None

    def create_post(self, message: MattermostMessage) -> dict[str, Any] | None:
        """Create a post in Mattermost (§M10)."""
        if not message.channel_id and message.channel_id != self.config.default_channel:
            # Try to resolve channel name to ID
            channel_id = self.get_channel_id(message.channel_id or self.config.default_channel)
            if channel_id:
                message.channel_id = channel_id
            else:
                logger.warning(f"Channel not found: {message.channel_id}")
                return None
        
        post_data = message.to_post_data()
        result = self._make_request("POST", "posts", data=post_data)
        return result

    def send_notification(
        self, 
        channel: str, 
        text: str, 
        username: str | None = None,
        icon_url: str | None = None,
    ) -> bool:
        """Send a notification to Mattermost (§M10).
        
        Args:
            channel: Channel name or ID
            text: Message text
            username: Override bot username
            icon_url: Override bot icon URL
            
        Returns:
            True if successful, False otherwise.
        """
        message = MattermostMessage(
            channel_id=channel,
            text=text,
            username=username or self.config.bot_username,
            icon_url=icon_url or "",
        )
        
        result = self.create_post(message)
        return result is not None

    def send_scheduler_event(
        self, 
        event_type: str, 
        workload_id: str, 
        details: dict[str, Any],
        channel: str | None = None,
    ) -> bool:
        """Send a scheduler event notification to Mattermost (§M10).
        
        Args:
            event_type: Type of scheduler event
            workload_id: ID of the workload
            details: Event details
            channel: Target channel (defaults to scheduler channel)
            
        Returns:
            True if successful, False otherwise.
        """
        target_channel = channel or self.config.default_channel
        
        # Format message based on event type
        if event_type == "workload_admitted":
            text = f"✅ Workload Admitted: `{workload_id}`\n" + \
                   f"Resources: CPU={details.get('cpu', 0)}, Memory={details.get('memory_mb', 0)}MB, GPU={details.get('gpu', 0)}"
        elif event_type == "workload_preempted":
            text = f"⚠️ Workload Preempted: `{workload_id}`\n" + \
                   f"Reason: {details.get('reason', 'priority preemption')}"
        elif event_type == "workload_released":
            text = f"🗑️ Workload Released: `{workload_id}`\n" + \
                   f"Duration: {details.get('duration', 'unknown')}"
        elif event_type == "reservation_created":
            text = f"📅 Reservation Created: `{workload_id}`\n" + \
                   f"Start: {details.get('start', 'unknown')}, End: {details.get('end', 'unknown')}"
        elif event_type == "calendar_triggered":
            text = f"🕐 Calendar Triggered: `{workload_id}`\n" + \
                   f"Scheduled: {details.get('scheduled_at', 'unknown')}"
        else:
            text = f"📊 Scheduler Event: {event_type} - {workload_id}\n" + \
                   f"Details: {json.dumps(details, indent=2)}"
        
        return self.send_notification(target_channel, text)

    def is_connected(self) -> bool:
        """Check if Mattermost connection is working."""
        result = self._make_request("GET", "users/me")
        return result is not None