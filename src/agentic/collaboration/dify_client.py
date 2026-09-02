"""src/agentic/collaboration/dify_client.py — Dify integration for AI collaboration (§M10)."""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Optional

import requests

logger = logging.getLogger(__name__)


@dataclass
class DifyConfig:
    """Configuration for Dify integration (§M10)."""
    server_url: str = "http://127.0.0.1:8080"
    api_key: str = ""
    default_workspace: str = "agentic"
    timeout_seconds: int = 30
    retry_count: int = 3
    retry_delay: float = 1.0


@dataclass 
class DifyWorkflow:
    """Represents a Dify workflow for AI collaboration (§M10)."""
    workflow_id: str = ""
    name: str = ""
    description: str = ""
    inputs: dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary format."""
        return {
            "workflow_id": self.workflow_id,
            "name": self.name,
            "description": self.description,
            "inputs": self.inputs,
        }


class DifyClient:
    """Client for Dify AI workflow platform (§M10).
    
    Provides integration with Dify for:
    - Executing AI workflows
    - Managing workflow templates
    - Collaborative AI decision making
    """

    def __init__(self, config: DifyConfig | None = None):
        """Initialize Dify client.
        
        Args:
            config: Dify configuration. Uses defaults if None.
        """
        self.config = config or DifyConfig()
        self._session = requests.Session()
        self._session.headers.update({
            "Authorization": f"Bearer {self.config.api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        })

    def _make_request(
        self, 
        method: str, 
        endpoint: str, 
        data: dict[str, Any] | None = None,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any] | list[dict[str, Any]] | None:
        """Make HTTP request to Dify API with retry logic."""
        url = f"{self.config.server_url}/{endpoint}"
        
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
                    logger.error("Dify authentication failed")
                    return None
                elif response.status_code == 404:
                    logger.debug(f"Dify endpoint not found: {endpoint}")
                    return None
                else:
                    logger.warning(f"Dify API error {response.status_code}: {response.text}")
                    
            except requests.RequestException as e:
                logger.warning(f"Dify request failed (attempt {attempt + 1}): {e}")
                if attempt < self.config.retry_count - 1:
                    time.sleep(self.config.retry_delay * (attempt + 1))
                    continue
                else:
                    logger.error(f"Dify request failed after all retries: {e}")
                    return None
        
        return None

    def list_workflows(self, workspace_id: str | None = None) -> list[dict[str, Any]] | None:
        """List available workflows in Dify (§M10)."""
        workspace = workspace_id or self.config.default_workspace
        result = self._make_request("GET", f"v1/workflows?workspace_id={workspace}")
        if result and isinstance(result, dict):
            return result.get("data", [])
        return None

    def get_workflow(self, workflow_id: str) -> dict[str, Any] | None:
        """Get workflow details by ID (§M10)."""
        result = self._make_request("GET", f"v1/workflows/{workflow_id}")
        return result

    def execute_workflow(
        self, 
        workflow_id: str, 
        inputs: dict[str, Any],
        user_id: str | None = None,
    ) -> dict[str, Any] | None:
        """Execute a Dify workflow with given inputs (§M10).
        
        Args:
            workflow_id: ID of the workflow to execute
            inputs: Input parameters for the workflow
            user_id: Optional user ID for context
            
        Returns:
            Workflow execution result or None if failed.
        """
        payload = {
            "inputs": inputs,
        }
        if user_id:
            payload["user_id"] = user_id
        
        result = self._make_request("POST", f"v1/workflows/{workflow_id}/run", data=payload)
        return result

    def execute_scheduler_decision(
        self, 
        workload_id: str,
        required_resources: dict[str, Any],
        system_status: dict[str, Any],
        user_id: str | None = None,
    ) -> dict[str, Any] | None:
        """Execute a scheduler decision workflow in Dify (§M10).
        
        This workflow can help make intelligent decisions about:
        - Resource allocation
        - Priority adjustments  
        - Preemption strategies
        - Load balancing
        
        Args:
            workload_id: The workload ID to make decision for
            required_resources: Resources requested by the workload
            system_status: Current system resource status
            user_id: Optional user context
            
        Returns:
            Decision result from Dify or None if failed.
        """
        inputs = {
            "workload_id": workload_id,
            "required_resources": required_resources,
            "system_status": system_status,
            "timestamp": int(time.time()),
        }
        
        # For now, use a generic decision workflow
        # In production, this would be a specific workflow ID
        decision_workflow_id = "scheduler-decision-workflow"
        
        return self.execute_workflow(decision_workflow_id, inputs, user_id)

    def send_collaboration_prompt(
        self, 
        prompt: str, 
        context: dict[str, Any],
        workflow_id: str | None = None,
        user_id: str | None = None,
    ) -> dict[str, Any] | None:
        """Send a collaboration prompt to Dify for processing (§M10).
        
        Args:
            prompt: The main prompt/text to process
            context: Additional context for the collaboration
            workflow_id: Optional specific workflow ID
            user_id: Optional user context
            
        Returns:
            Processing result from Dify or None if failed.
        """
        inputs = {
            "prompt": prompt,
            "context": context,
            "timestamp": int(time.time()),
        }
        
        target_workflow = workflow_id or "collaboration-prompt-workflow"
        return self.execute_workflow(target_workflow, inputs, user_id)

    def is_connected(self) -> bool:
        """Check if Dify connection is working."""
        result = self._make_request("GET", "v1/workflows")
        return result is not None