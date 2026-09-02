"""Adapter contracts for v2 (§3.2).

ABCs: HarnessAdapter, AgentRuntimeAdapter, ApplicationAdapter,
      GPUJobAdapter, ManagedServiceAdapter, ModelBrokerAdapter,
      RAGServiceAdapter, GitProviderAdapter, ExternalAccessBroker.
"""

from .adapters import (
    AgentCapabilities,
    ToolCallMode,
    HarnessAdapter,
    AgentRuntimeAdapter,
    ApplicationAdapter,
    GPUJobAdapter,
    ManagedServiceAdapter,
    ModelBrokerAdapter,
    RAGServiceAdapter,
    GitProviderAdapter,
    ExternalAccessBroker,
)

__all__ = [
    "AgentCapabilities",
    "ToolCallMode",
    "HarnessAdapter",
    "AgentRuntimeAdapter",
    "ApplicationAdapter",
    "GPUJobAdapter",
    "ManagedServiceAdapter",
    "ModelBrokerAdapter",
    "RAGServiceAdapter",
    "GitProviderAdapter",
    "ExternalAccessBroker",
]
