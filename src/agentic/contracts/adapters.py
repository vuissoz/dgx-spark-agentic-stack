#!/usr/bin/env python3
"""src/agentic/contracts/adapters.py — Interface contracts for v2 adapters (§3.2).

These ABCs define the responsibilities each adapter must fulfill.
They do not simulate capabilities; they expose what is available.
Implementations are expected under src/agentic/implementations/.
"""

from __future__ import annotations

import abc
import enum
from dataclasses import dataclass, field
from typing import Any, Optional


class ToolCallMode(enum.Enum):
    STREAMING = "streaming"
    BATCH = "batch"
    NONE = "none"


@dataclass(frozen=True)
class AgentCapabilities:
    """Declared capabilities for a harness definition."""
    tool_call_mode: ToolCallMode = ToolCallMode.STREAMING
    supports_sub_agents: bool = False
    max_depth: int = 1
    supports_streaming: bool = True
    requires_gpu: bool = False
    allowed_network_domains: list[str] = field(default_factory=list)


class HarnessAdapter(abc.ABC):
    """Protocol model, sessions, sub-agents, tools, permissions, and surfaces."""

    @property
    @abc.abstractmethod
    def capabilities(self) -> AgentCapabilities: ...

    @abc.abstractmethod
    async def start_session(self, agent_identity: str, project: Optional[str] = None, **kwargs: Any) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def end_session(self, session_id: str) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def submit_tool_call(self, session_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def list_sessions(self, agent_identity: Optional[str] = None) -> list[dict[str, Any]]: ...


class AgentRuntimeAdapter(abc.ABC):
    """OpenShell execution envelope."""

    @abc.abstractmethod
    async def provision_sandbox(self, context: dict[str, Any]) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def observe_sandbox(self, sandbox_id: str) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def teardown_sandbox(self, sandbox_id: str) -> bool: ...

    @abc.abstractmethod
    async def apply_limits(self, sandbox_id: str, cpu: float, memory_mb: int, gpu: bool = False) -> bool: ...


class ApplicationAdapter(abc.ABC):
    """Lifecycle for human-facing applications (OpenWebUI, ComfyUI, Forgejo, etc.)."""

    @property
    @abc.abstractmethod
    def service_name(self) -> str: ...

    @abc.abstractmethod
    async def start(self) -> bool: ...

    @abc.abstractmethod
    async def health_check(self) -> bool: ...

    @abc.abstractmethod
    def status_url(self) -> str: ...

    @abc.abstractmethod
    async def backup(self, dest: str) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def restore(self, source: str) -> dict[str, Any]: ...


class GPUJobAdapter(abc.ABC):
    """Admission and observation of GPU tasks (e.g., ComfyUI workflows)."""

    @abc.abstractmethod
    async def admit_job(self, job: dict[str, Any]) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def observe_job(self, job_id: str) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def cancel_job(self, job_id: str) -> bool: ...


class ManagedServiceAdapter(abc.ABC):
    """Internal managed services (PostgreSQL, Unbound, etc.)."""

    @property
    @abc.abstractmethod
    def service_name(self) -> str: ...

    @abc.abstractmethod
    async def health(self) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def configure(self, config: dict[str, Any]) -> bool: ...


class ModelBrokerAdapter(abc.ABC):
    """Model protocols and backends."""

    @abc.abstractmethod
    async def list_models(self) -> list[dict[str, Any]]: ...

    @abc.abstractmethod
    async def route_model_request(
        self,
        user_id: str,
        project: Optional[str],
        model_alias: str,
        payload: dict[str, Any],
    ) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def get_quota(self, user_id: str) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def fallback_to_backend(self, backend_name: str) -> bool: ...


class RAGServiceAdapter(abc.ABC):
    """RAG v1 service adapter."""

    @abc.abstractmethod
    async def health(self) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def capabilities(self) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def config(self) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def submit_task(self, task_def: dict[str, Any]) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def retrieve(self, query: str, project: Optional[str] = None) -> list[dict[str, Any]]: ...

    @abc.abstractmethod
    async def snapshot(self) -> dict[str, Any]: ...


class GitProviderAdapter(abc.ABC):
    """Forgejo/GitHub integration."""

    @property
    @abc.abstractmethod
    def provider_name(self) -> str: ...

    @abc.abstractmethod
    async def list_repos(self, user_id: str) -> list[dict[str, Any]]: ...

    @abc.abstractmethod
    async def push(self, repo: str, branch: str, payload: dict[str, Any]) -> bool: ...


class ExternalAccessBroker(abc.ABC):
    """Short-lived credentials for GitHub, HF, and future services."""

    @abc.abstractmethod
    async def rotate_credentials(self, service: str, scope: str) -> dict[str, Any]: ...

    @abc.abstractmethod
    async def revoke_credentials(self, token_id: str) -> bool: ...

    @abc.abstractmethod
    async def health_check(self) -> bool: ...
