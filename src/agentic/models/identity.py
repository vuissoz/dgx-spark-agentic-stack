#!/usr/bin/env python3
"""src/agentic/models/identity.py — Identity, project, session, and multi-agent objects (§5).

Data model for AgentDefinition, AgentIdentity, RuntimeContext, Session, Run, and Project.
Each object defines invariants required by PLAN.md §5.
"""

from __future__ import annotations

import enum
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional


class OrchestrationMode(enum.Enum):
    NONE = "none"
    NATIVE = "native"
    PLATFORM = "platform"
    EXTERNAL_PROVIDER = "external-provider"


@dataclass(frozen=True)
class AgentDefinition:
    """Canonical definition of a harness with version, image, capabilities, and surfaces."""
    harness_name: str
    version: str
    image_tag: str
    capabilities: list[str] = field(default_factory=list)
    primary_surface: str = "cli"  # cli, web, desktop, ide, acp, messaging
    allowed_network_domains: list[str] = field(default_factory=list)

    def is_compatible_with(self, required_capability: str) -> bool:
        return required_capability in self.capabilities


@dataclass(frozen=True)
class AgentIdentity:
    """Logical collaborator identity that persists across sessions."""
    user_id: str
    identity_id: str = field(default_factory=lambda: uuid.uuid4().hex[:8])
    roles: list[str] = field(default_factory=list)
    projects: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class Project:
    """Rights, workspace, secrets, models, and collections per project."""
    project_id: str
    owner: AgentIdentity
    workspace_path: str = ""
    allowed_models: list[str] = field(default_factory=list)
    rag_collection_prefix: str = field(default_factory=lambda: uuid.uuid4().hex[:6])
    secrets_scope: str = "*"  # * for global, project-specific otherwise


@dataclass(frozen=True)
class Session:
    """Conversation or native task with parent correlation."""
    session_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    run_id: Optional[str] = None
    parent_run_id: Optional[str] = None
    harness: str = ""
    state: str = "active"  # active, paused, completed, failed


@dataclass(frozen=True)
class Run:
    """Correlated execution, possibly parent or child."""
    run_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    parent_run_id: Optional[str] = None
    user_id: str = ""
    project_id: Optional[str] = None
    harness: str = ""
    started_at: Optional[str] = None
    finished_at: Optional[str] = None
    metrics: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class RuntimeContext:
    """Execution context for user + agent + project.
    
    Invariant (§5.3): A mutable shared HOME across projects is prohibited by default.
    Context is keyed by: user + agent_identity + project
    """
    key: str = ""
    user: AgentIdentity | None = None
    agent_def: AgentDefinition | None = None
    project: Project | None = None
    active_session: Session | None = None
    active_run: Run | None = None
    orchestration_mode: OrchestrationMode = OrchestrationMode.NONE
    max_depth: int = 1
    max_concurrency: int = 1

    def is_empty(self) -> bool:
        return self.key == "" or (self.user is None and self.project is None)

    def requires_isolation(self) -> bool:
        return self.project is not None

    def allows_sub_agents(self) -> bool:
        if self.agent_def and self.agent_def.is_compatible_with("sub-agents"):
            return True
        return False
