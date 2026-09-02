#!/usr/bin/env python3
"""src/agentic/contracts/agents.py — Vertical contracts for M6 code agents (§M6, §G6).

Each M6 agent has a specific vertical contract that defines its unique capabilities,
protocols, and constraints. These contracts extend the base HarnessAdapter contract
with agent-specific behavior and validation rules.

Conforms to PLAN.md §M6 (Agents de code) and §G6 (contrat vertical et tests négatifs verts).
"""

from __future__ import annotations

import abc
from dataclasses import dataclass, field
from typing import Any, Optional


@dataclass(frozen=True)
class AgentCapabilities:
    """Extended capabilities specific to each M6 agent."""
    # Base harness capabilities
    tool_call_mode: str = "streaming"
    supports_sub_agents: bool = False
    max_depth: int = 1
    supports_streaming: bool = True
    requires_gpu: bool = False
    
    # Agent-specific capabilities
    supports_model_routing: bool = False
    supports_extensions: bool = False
    supports_github_integration: bool = False
    supports_huggingface_integration: bool = False
    supports_repo_e2e: bool = False
    supports_native_surfaces: list[str] = field(default_factory=list)
    model_protocols: list[str] = field(default_factory=list)


class M6AgentContract(abc.ABC):
    """Base vertical contract for all M6 agents.
    
    Each M6 agent must implement this contract to ensure consistent behavior
    across the platform. This contract extends the HarnessAdapter with
    agent-specific functionality.
    """
    
    @property
    @abc.abstractmethod
    def agent_name(self) -> str:
        """Unique identifier for the agent (e.g., 'codex', 'claude')."""
        ...
    
    @property
    @abc.abstractmethod
    def capabilities(self) -> AgentCapabilities:
        """Agent-specific capabilities and constraints."""
        ...
    
    @abc.abstractmethod
    async def validate_model_protocol(self, protocol: str) -> bool:
        """Validate that the agent supports the given model protocol."""
        ...
    
    @abc.abstractmethod
    async def validate_extensions(self, extensions: list[str]) -> list[str]:
        """Validate agent extensions. Returns list of validation errors."""
        ...
    
    @abc.abstractmethod
    async def validate_github_integration(self, config: dict[str, Any]) -> bool:
        """Validate GitHub integration configuration for the agent."""
        ...
    
    @abc.abstractmethod
    async def validate_huggingface_integration(self, config: dict[str, Any]) -> bool:
        """Validate HuggingFace integration configuration for the agent."""
        ...
    
    @abc.abstractmethod
    async def validate_repo_e2e_compatibility(self) -> bool:
        """Validate that the agent supports repo-e2e testing framework."""
        ...
    
    @abc.abstractmethod
    async def get_native_surfaces(self) -> list[str]:
        """Get list of native surfaces supported by this agent."""
        ...


# =============================================================================
# Individual M6 Agent Contracts
# =============================================================================

class CodexContract(M6AgentContract):
    """Vertical contract for Codex agent (§M6).
    
    Conforms to §6.3 protocol table: OpenAI Responses `/v1/responses`
    Supports: OpenAI Responses API, tool calling, streaming, approvals
    """
    
    @property
    def agent_name(self) -> str:
        return "codex"
    
    @property
    def capabilities(self) -> AgentCapabilities:
        return AgentCapabilities(
            tool_call_mode="streaming",
            supports_sub_agents=False,
            max_depth=1,
            supports_streaming=True,
            requires_gpu=False,
            supports_model_routing=True,
            supports_extensions=True,
            supports_github_integration=True,
            supports_huggingface_integration=False,
            supports_repo_e2e=True,
            supports_native_surfaces=["cli", "ide", "web"],
            model_protocols=["openai_responses", "openai_chat_completions"],
        )
    
    async def validate_model_protocol(self, protocol: str) -> bool:
        return protocol in ["openai_responses", "openai_chat_completions"]
    
    async def validate_extensions(self, extensions: list[str]) -> list[str]:
        errors = []
        # Codex supports extensions but with restrictions
        for ext in extensions:
            if ext.startswith("docker_"):
                errors.append(f"Codex does not support docker extensions: {ext}")
        return errors
    
    async def validate_github_integration(self, config: dict[str, Any]) -> bool:
        # Codex supports GitHub integration via extensions
        return bool(config.get("enabled", False) and config.get("token"))
    
    async def validate_huggingface_integration(self, config: dict[str, Any]) -> bool:
        # Codex does not natively support HuggingFace
        return False
    
    async def validate_repo_e2e_compatibility(self) -> bool:
        # Codex has full repo-e2e support
        return True
    
    async def get_native_surfaces(self) -> list[str]:
        return ["cli", "ide", "web"]


class ClaudeContract(M6AgentContract):
    """Vertical contract for Claude Code agent (§M6).
    
    Conforms to §6.3 protocol table: Anthropic Messages `/v1/messages`
    Supports: Anthropic Messages API, tool calling, streaming, sub-agents, MCP
    """
    
    @property
    def agent_name(self) -> str:
        return "claude"
    
    @property
    def capabilities(self) -> AgentCapabilities:
        return AgentCapabilities(
            tool_call_mode="streaming",
            supports_sub_agents=True,
            max_depth=3,
            supports_streaming=True,
            requires_gpu=False,
            supports_model_routing=True,
            supports_extensions=True,
            supports_github_integration=True,
            supports_huggingface_integration=True,
            supports_repo_e2e=True,
            supports_native_surfaces=["cli", "web"],
            model_protocols=["anthropic_messages", "openai_chat_completions"],
        )
    
    async def validate_model_protocol(self, protocol: str) -> bool:
        return protocol in ["anthropic_messages", "openai_chat_completions"]
    
    async def validate_extensions(self, extensions: list[str]) -> list[str]:
        errors = []
        # Claude supports MCP and other extensions
        for ext in extensions:
            if ext.startswith("mcp_") and not ext.startswith("mcp_approved_"):
                errors.append(f"MCP extension not in allowlist: {ext}")
        return errors
    
    async def validate_github_integration(self, config: dict[str, Any]) -> bool:
        return bool(config.get("enabled", False) and config.get("token"))
    
    async def validate_huggingface_integration(self, config: dict[str, Any]) -> bool:
        return bool(config.get("enabled", False) and config.get("token"))
    
    async def validate_repo_e2e_compatibility(self) -> bool:
        return True
    
    async def get_native_surfaces(self) -> list[str]:
        return ["cli", "web"]


class OpenCodeContract(M6AgentContract):
    """Vertical contract for OpenCode agent (§M6).
    
    Conforms to §6.3 protocol table: Chat Completions API
    Supports: Chat completions, tool calling, streaming, web UI
    """
    
    @property
    def agent_name(self) -> str:
        return "opencode"
    
    @property
    def capabilities(self) -> AgentCapabilities:
        return AgentCapabilities(
            tool_call_mode="streaming",
            supports_sub_agents=False,
            max_depth=1,
            supports_streaming=True,
            requires_gpu=False,
            supports_model_routing=True,
            supports_extensions=True,
            supports_github_integration=True,
            supports_huggingface_integration=True,
            supports_repo_e2e=True,
            supports_native_surfaces=["cli", "web"],
            model_protocols=["chat_completions", "openai_chat_completions"],
        )
    
    async def validate_model_protocol(self, protocol: str) -> bool:
        return protocol in ["chat_completions", "openai_chat_completions"]
    
    async def validate_extensions(self, extensions: list[str]) -> list[str]:
        errors = []
        # OpenCode has extension system
        for ext in extensions:
            if ext.endswith("_unsafe"):
                errors.append(f"Unsafe extension not allowed: {ext}")
        return errors
    
    async def validate_github_integration(self, config: dict[str, Any]) -> bool:
        return bool(config.get("enabled", False) and config.get("token"))
    
    async def validate_huggingface_integration(self, config: dict[str, Any]) -> bool:
        return bool(config.get("enabled", False) and config.get("token"))
    
    async def validate_repo_e2e_compatibility(self) -> bool:
        return True
    
    async def get_native_surfaces(self) -> list[str]:
        return ["cli", "web"]


class KiloCodeContract(M6AgentContract):
    """Vertical contract for KiloCode agent (§M6).
    
    Conforms to §6.3 protocol table: Ollama Native
    Supports: Ollama native integration, tool calling, multi-agent
    """
    
    @property
    def agent_name(self) -> str:
        return "kilocode"
    
    @property
    def capabilities(self) -> AgentCapabilities:
        return AgentCapabilities(
            tool_call_mode="streaming",
            supports_sub_agents=True,
            max_depth=2,
            supports_streaming=True,
            requires_gpu=False,
            supports_model_routing=True,
            supports_extensions=False,
            supports_github_integration=True,
            supports_huggingface_integration=False,
            supports_repo_e2e=True,
            supports_native_surfaces=["cli", "ide", "web_console"],
            model_protocols=["ollama_native", "openai_chat_completions"],
        )
    
    async def validate_model_protocol(self, protocol: str) -> bool:
        return protocol in ["ollama_native", "openai_chat_completions"]
    
    async def validate_extensions(self, extensions: list[str]) -> list[str]:
        errors = []
        # KiloCode does not support extensions in the same way
        if extensions:
            errors.append("KiloCode does not support extensions")
        return errors
    
    async def validate_github_integration(self, config: dict[str, Any]) -> bool:
        return bool(config.get("enabled", False) and config.get("token"))
    
    async def validate_huggingface_integration(self, config: dict[str, Any]) -> bool:
        return False
    
    async def validate_repo_e2e_compatibility(self) -> bool:
        return True
    
    async def get_native_surfaces(self) -> list[str]:
        return ["cli", "ide", "web_console"]


class VibeContract(M6AgentContract):
    """Vertical contract for Vibe (Mistral Vibe) agent (§M6).
    
    Conforms to §6.3 protocol table: Configurable endpoint
    Supports: Multiple LLM providers, extensions, ACP integration
    """
    
    @property
    def agent_name(self) -> str:
        return "vibestral"
    
    @property
    def capabilities(self) -> AgentCapabilities:
        return AgentCapabilities(
            tool_call_mode="streaming",
            supports_sub_agents=False,
            max_depth=1,
            supports_streaming=True,
            requires_gpu=False,
            supports_model_routing=True,
            supports_extensions=True,
            supports_github_integration=True,
            supports_huggingface_integration=True,
            supports_repo_e2e=True,
            supports_native_surfaces=["cli", "vscode", "acp"],
            model_protocols=["configurable_endpoint", "openai_chat_completions", "anthropic_messages"],
        )
    
    async def validate_model_protocol(self, protocol: str) -> bool:
        return protocol in ["configurable_endpoint", "openai_chat_completions", "anthropic_messages"]
    
    async def validate_extensions(self, extensions: list[str]) -> list[str]:
        errors = []
        # Vibe supports rich extension system
        for ext in extensions:
            if ext.startswith("vibe_"):
                continue  # Built-in extensions are allowed
            elif ext.startswith("custom_"):
                errors.append(f"Custom extension requires review: {ext}")
        return errors
    
    async def validate_github_integration(self, config: dict[str, Any]) -> bool:
        return bool(config.get("enabled", False) and config.get("token"))
    
    async def validate_huggingface_integration(self, config: dict[str, Any]) -> bool:
        return bool(config.get("enabled", False) and config.get("token"))
    
    async def validate_repo_e2e_compatibility(self) -> bool:
        return True
    
    async def get_native_surfaces(self) -> list[str]:
        return ["cli", "vscode", "acp"]


class PiContract(M6AgentContract):
    """Vertical contract for Pi (pi-coding-agent) agent (§M6).
    
    Conforms to §6.3 protocol table: Configurable protocol
    Supports: Multiple protocols, desktop integration, extensions
    """
    
    @property
    def agent_name(self) -> str:
        return "pi"
    
    @property
    def capabilities(self) -> AgentCapabilities:
        return AgentCapabilities(
            tool_call_mode="streaming",
            supports_sub_agents=False,
            max_depth=1,
            supports_streaming=True,
            requires_gpu=False,
            supports_model_routing=True,
            supports_extensions=True,
            supports_github_integration=True,
            supports_huggingface_integration=False,
            supports_repo_e2e=True,
            supports_native_surfaces=["cli", "desktop"],
            model_protocols=["configurable", "openai_chat_completions", "anthropic_messages"],
        )
    
    async def validate_model_protocol(self, protocol: str) -> bool:
        return protocol in ["configurable", "openai_chat_completions", "anthropic_messages"]
    
    async def validate_extensions(self, extensions: list[str]) -> list[str]:
        errors = []
        # Pi supports extensions with validation
        for ext in extensions:
            if ext.startswith("pi_"):
                continue  # Built-in extensions are allowed
            elif len(ext) > 50:
                errors.append(f"Extension name too long: {ext}")
        return errors
    
    async def validate_github_integration(self, config: dict[str, Any]) -> bool:
        return bool(config.get("enabled", False) and config.get("token"))
    
    async def validate_huggingface_integration(self, config: dict[str, Any]) -> bool:
        return False
    
    async def validate_repo_e2e_compatibility(self) -> bool:
        return True
    
    async def get_native_surfaces(self) -> list[str]:
        return ["cli", "desktop"]


class GooseContract(M6AgentContract):
    """Vertical contract for Goose agent (§M6).
    
    Conforms to §6.3 protocol table: Chat Completions API
    Supports: Multiple providers, recipe system, ACP integration
    """
    
    @property
    def agent_name(self) -> str:
        return "goose"
    
    @property
    def capabilities(self) -> AgentCapabilities:
        return AgentCapabilities(
            tool_call_mode="streaming",
            supports_sub_agents=True,
            max_depth=2,
            supports_streaming=True,
            requires_gpu=False,
            supports_model_routing=True,
            supports_extensions=True,
            supports_github_integration=True,
            supports_huggingface_integration=True,
            supports_repo_e2e=True,
            supports_native_surfaces=["cli", "acp"],
            model_protocols=["chat_completions", "openai_chat_completions"],
        )
    
    async def validate_model_protocol(self, protocol: str) -> bool:
        return protocol in ["chat_completions", "openai_chat_completions"]
    
    async def validate_extensions(self, extensions: list[str]) -> list[str]:
        errors = []
        # Goose has recipe and extension system
        for ext in extensions:
            if ext.startswith("recipe_"):
                continue  # Recipe extensions are allowed
            elif ext.startswith("provider_"):
                continue  # Provider extensions are allowed
        return errors
    
    async def validate_github_integration(self, config: dict[str, Any]) -> bool:
        return bool(config.get("enabled", False) and config.get("token"))
    
    async def validate_huggingface_integration(self, config: dict[str, Any]) -> bool:
        return bool(config.get("enabled", False) and config.get("token"))
    
    async def validate_repo_e2e_compatibility(self) -> bool:
        return True
    
    async def get_native_surfaces(self) -> list[str]:
        return ["cli", "acp"]


# =============================================================================
# M6 Agent Contract Registry
# =============================================================================

def get_m6_agent_contracts() -> dict[str, type[M6AgentContract]]:
    """Return all M6 agent contracts."""
    return {
        "codex": CodexContract,
        "claude": ClaudeContract,
        "opencode": OpenCodeContract,
        "kilocode": KiloCodeContract,
        "vibestral": VibeContract,
        "pi": PiContract,
        "goose": GooseContract,
    }


def get_agent_contract(agent_name: str) -> Optional[M6AgentContract]:
    """Get the contract for a specific M6 agent."""
    contracts = get_m6_agent_contracts()
    if agent_name in contracts:
        return contracts[agent_name]()
    return None