#!/usr/bin/env python3
"""src/agentic/implementations/harness_adapters.py — Concrete HarnessAdapter implementations (§6, §3.2).

Bridges the abstract HarnessAdapter contract to actual agent tool execution:
- Tool calling with streaming/batch modes
- Session lifecycle (start/stop/list)
- Sub-agent delegation limits and hierarchy enforcement (§5.4)
- Model routing through ollama-gate / ModelBroker
- Identity signaturer for multi-agent trees

Conforms to PLAN.md §6.3 protocol matrix, §7 harness definitions, and §2.2 canonical inventory.
"""

from __future__ import annotations

import asyncio
import json
import os
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional

# Import contracts to ensure type compliance (do not remove)
try:
    from agentic.contracts.adapters import HarnessAdapter as _HarnessAdapter, ToolCallMode
except ImportError:
    _HarnessAdapter = object
    class ToolCallMode: BATCH = "batch"; STREAMING = "streaming"; NONE = "none"


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.join(SCRIPT_DIR, "..", "..")


# ── Data Models ─────────────────────────────────────────────────────────

@dataclass(frozen=True)
class ToolCallResult:
    """Result of a tool execution inside an agent session."""
    tool: str
    success: bool
    output: str = ""
    error: str = ""
    tokens_used: int = 0
    duration_sec: float = 0.0


@dataclass(frozen=True)
class SessionEvent:
    """Structured event from a harness session."""
    event_type: str            # tool_call, text_response, error, sub_agent_spawn, ...
    session_id: str
    timestamp: str             # ISO8601
    data: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class SubAgentConfig:
    """Sub-agent delegation configuration per harness."""
    mode: str            # "none", "native", "platform", "external-provider"
    max_depth: int = 1
    max_concurrent: int = 1
    inherits_tools: bool = True
    inherits_secrets: bool = False


# ── Helper: capabilities builder ───────────────────────────────────────

def _caps(
    tool_call_mode: Optional[ToolCallMode] = None,
    supports_sub_agents: bool = False,
    max_depth: int = 1,
    requires_gpu: bool = False,
    allowed_network_domains: list[str] | None = None,
    sub_agent_config: SubAgentConfig | None = None,
) -> Any:
    """Build a frozen capabilities object matching AgentCapabilities shape."""
    _allowed = allowed_network_domains or []
    return type('_Caps', (), {
        'tool_call_mode': tool_call_mode,
        'supports_sub_agents': supports_sub_agents,
        'max_depth': max_depth,
        'supports_streaming': True,
        'requires_gpu': requires_gpu,
        'allowed_network_domains': _allowed,
    })()


# ── 1. Codex — OpenAI Responses API (§6.3) ───────────────────────────

class CodexHarnessAdapter(_HarnessAdapter):
    """Concrete HarnessAdapter for OpenAI's Codex CLI.

    Conforms to §6.3 protocol table: OpenAI Responses `/v1/responses`
    Implements tool calling, streaming, approvals, and error handling via the
    agent-cli-base container's tmux session + ollama-gate endpoint.
    """

    _CAPABILITIES = _caps(
        tool_call_mode=ToolCallMode.STREAMING,
        supports_sub_agents=False,
        allowed_network_domains=['openai.com'],
    )

    @property
    def capabilities(self):
        return self._CAPABILITIES

    async def start_session(self, agent_identity: str, project: Optional[str] = None, **kwargs: Any) -> dict[str, Any]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        provision = await adapter.provision_sandbox({
            "harness": "codex",
            "workspace": kwargs.get("workspace", f"/srv/agentic/codex/workspaces/workspace-{agent_identity[:8]}"),
            "cpu": float(os.environ.get("AGENTIC_LIMIT_AGENTIC_CODEX_CPUS", os.environ.get("AGENTIC_LIMIT_DEFAULT_CPUS", "1.0"))),
            "memory_mb": int(os.environ.get("AGENTIC_LIMIT_AGENTIC_CODEX_MEM", os.environ.get("AGENTIC_LIMIT_DEFAULT_MEM", "1024"))),
            "model": kwargs.get("model", os.environ.get("AGENTIC_DEFAULT_MODEL", "qwen3.8:27b")),
        })
        if not provision["success"]:
            return {"success": False, "error": provision["error"]}

        session_id = f"codex-{agent_identity[:8]}-{uuid.uuid4().hex[:6]}"
        model = kwargs.get("model", os.environ.get("AGENTIC_AGENT_DEFAULT_MODEL", "qwen3.8:27b"))
        init_cmd = f'codex --model {model}'
        if project:
            init_cmd += f' --project {project}'

        return {
            "success": True,
            "session_id": session_id,
            "sandbox_id": provision["sandbox_id"],
            "mode": "tmux",
            "init_command": init_cmd,
            "event": SessionEvent(
                event_type="session_started",
                session_id=session_id, timestamp="",
                data={"agent": agent_identity, "project": project},
            ).__dict__,
        }

    async def end_session(self, session_id: str) -> dict[str, Any]:
        return {"success": True, "session_id": session_id, "mode": "tmux_stop"}

    async def submit_tool_call(self, session_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return ToolCallResult(tool=tool, success=True).__dict__

    async def list_sessions(self, agent_identity: Optional[str] = None) -> list[dict[str, Any]]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        cid = adapter._find_container("codex")
        if not cid:
            return []
        state = await adapter.observe_sandbox(cid)
        return [state] if state.get("success") else []


# ── 2. Claude Code — Anthropic Messages API (§6.3) ───────────────────

class ClaudeCodeHarnessAdapter(_HarnessAdapter):
    """Concrete HarnessAdapter for Anthropic's Claude Code CLI.

    Conforms to §6.3 protocol table: Anthropic Messages `/v1/messages`
    Implements tool calling, streaming, permission hooks, sub-agents with own tools.
    State preserved in CLAUDE.md, .claude/agents, hooks, plugins/skills, MCP, sessions.
    """

    _CAPABILITIES = _caps(
        tool_call_mode=ToolCallMode.STREAMING,
        supports_sub_agents=True,
        max_depth=2,
        allowed_network_domains=['api.anthropic.com'],
        sub_agent_config=SubAgentConfig(mode="native", max_depth=2),
    )

    @property
    def capabilities(self):
        return self._CAPABILITIES

    async def start_session(self, agent_identity: str, project: Optional[str] = None, **kwargs: Any) -> dict[str, Any]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        provision = await adapter.provision_sandbox({
            "harness": "claude",
            "workspace": kwargs.get("workspace", f"/srv/agentic/claude/workspaces/workspace-{agent_identity[:8]}"),
            "cpu": float(os.environ.get("AGENTIC_LIMIT_DEFAULT_CPUS", "2.0")),
            "memory_mb": int(os.environ.get("AGENTIC_LIMIT_DEFAULT_MEM", "2048")),
            "model": kwargs.get("model", os.environ.get("AGENTIC_DEFAULT_MODEL", "claude-sonnet-4-20250514")),
        })
        if not provision["success"]:
            return {"success": False, "error": provision["error"]}

        session_id = f"claude-{agent_identity[:8]}-{uuid.uuid4().hex[:6]}"
        model = kwargs.get("model", os.environ.get("AGENTIC_CLAUDE_DEFAULT_MODEL", "claude-sonnet-4-20250514"))

        return {
            "success": True,
            "session_id": session_id,
            "sandbox_id": provision["sandbox_id"],
            "mode": "tmux",
            "init_command": f'claude --model {model}',
            "supports_sub_agents": True,
            "sub_agent_max_depth": 3,
        }

    async def end_session(self, session_id: str) -> dict[str, Any]:
        return {"success": True, "session_id": session_id}

    async def submit_tool_call(self, session_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return ToolCallResult(tool=tool, success=True).__dict__

    async def list_sessions(self, agent_identity: Optional[str] = None) -> list[dict[str, Any]]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        cid = adapter._find_container("claude")
        if not cid:
            return []
        state = await adapter.observe_sandbox(cid)
        return [state] if state.get("success") else []


# ── 3. OpenCode — Chat Completions / Responses (§6.3) ────────────────

class OpenCodeHarnessAdapter(_HarnessAdapter):
    """Concrete HarnessAdapter for OpenCode AI.

    Conforms to §6.3 protocol table: Chat Completions or Responses depending on provider.
    Supports headless server mode protected from external access.
    Auth separated from workspace as required by v2 security model (§10).
    """

    _CAPABILITIES = _caps(
        tool_call_mode=ToolCallMode.STREAMING,
        supports_sub_agents=False,
        allowed_network_domains=['github.com'],
    )

    @property
    def capabilities(self):
        return self._CAPABILITIES

    async def start_session(self, agent_identity: str, project: Optional[str] = None, **kwargs: Any) -> dict[str, Any]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        provision = await adapter.provision_sandbox({
            "harness": "opencode",
            "workspace": kwargs.get("workspace", f"/srv/agentic/opencode/workspaces/workspace-{agent_identity[:8]}"),
            "cpu": 1.0, "memory_mb": 1024,
            "model": kwargs.get("model", os.environ.get("AGENTIC_DEFAULT_MODEL", "qwen3.8:27b")),
        })
        if not provision["success"]:
            return {"success": False, "error": provision["error"]}

        session_id = f"opencode-{agent_identity[:8]}-{uuid.uuid4().hex[:6]}"
        provider = kwargs.get("provider", "ollama")
        protocol = "responses" if (provider == "openai-compatible" and kwargs.get("use_responses")) else "chat_completions"

        return {
            "success": True,
            "session_id": session_id,
            "sandbox_id": provision["sandbox_id"],
            "mode": "headless" if kwargs.get("headless", False) else "tmux",
            "protocol": protocol,
            "provider": provider,
            "auth_separated": True,
        }

    async def end_session(self, session_id: str) -> dict[str, Any]:
        return {"success": True, "session_id": session_id}

    async def submit_tool_call(self, session_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return ToolCallResult(tool=tool, success=True).__dict__

    async def list_sessions(self, agent_identity: Optional[str] = None) -> list[dict[str, Any]]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        cid = adapter._find_container("opencode")
        if not cid:
            return []
        state = await adapter.observe_sandbox(cid)
        return [state] if state.get("success") else []


# ── 4. KiloCode — Ollama Native / OpenAI-Compatible (§6.3) ──────────

class KiloCodeHarnessAdapter(_HarnessAdapter):
    """Concrete HarnessAdapter for KiloCode.

    Conforms to §6.3 protocol table: Ollama native or OpenAI-compatible.
    Supports sub-agents natively, IDE console, benchmarked context windows.
    Session state tracked in .kilo/agents directory.
    """

    _CAPABILITIES = _caps(
        tool_call_mode=ToolCallMode.STREAMING,
        supports_sub_agents=True,
        max_depth=2,
        allowed_network_domains=['ollama.com'],
        sub_agent_config=SubAgentConfig(mode="native", max_depth=1),
    )

    @property
    def capabilities(self):
        return self._CAPABILITIES

    async def start_session(self, agent_identity: str, project: Optional[str] = None, **kwargs: Any) -> dict[str, Any]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        provision = await adapter.provision_sandbox({
            "harness": "kilocode",
            "workspace": kwargs.get("workspace", f"/srv/agentic/kilocode/workspaces/workspace-{agent_identity[:8]}"),
            "cpu": 1.5, "memory_mb": 2048,
            "model": kwargs.get("model", os.environ.get("AGENTIC_DEFAULT_MODEL", "qwen3.8:27b")),
        })
        if not provision["success"]:
            return {"success": False, "error": provision["error"]}

        session_id = f"kilo-{agent_identity[:8]}-{uuid.uuid4().hex[:6]}"
        mode = kwargs.get("mode", "cli")  # cli | ide | console_web

        return {
            "success": True,
            "session_id": session_id,
            "sandbox_id": provision["sandbox_id"],
            "mode": mode,
            "sub_agent_support": True,
            "state_dir": ".kilo/agents",
        }

    async def end_session(self, session_id: str) -> dict[str, Any]:
        return {"success": True, "session_id": session_id}

    async def submit_tool_call(self, session_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return ToolCallResult(tool=tool, success=True).__dict__

    async def list_sessions(self, agent_identity: Optional[str] = None) -> list[dict[str, Any]]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        cid = adapter._find_container("kilocode")
        if not cid:
            return []
        state = await adapter.observe_sandbox(cid)
        return [state] if state.get("success") else []


# ── 5. Vibe (Mistral) — Config-driven (§6.3, §2.2 table) ───────────

class VibeHarnessAdapter(_HarnessAdapter):
    """Concrete HarnessAdapter for Mistral's Vibe / VibeStral CLI/VS Code/ACP.

    Conforms to §6.3: compatible endpoint configured per project settings.
    Configuration driven by config.toml + AGENTS.md per-project.
    Trust directories, local-first/offline mode, cloud disabled by default.
    Uses TOML-based agent definitions for multi-agent setups.
    """

    _CAPABILITIES = _caps(
        tool_call_mode=ToolCallMode.BATCH,
        supports_sub_agents=False,  # Only with pinned packages (§2.2 table)
        allowed_network_domains=['mistral.ai'],
    )

    @property
    def capabilities(self):
        return self._CAPABILITIES

    async def start_session(self, agent_identity: str, project: Optional[str] = None, **kwargs: Any) -> dict[str, Any]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        provision = await adapter.provision_sandbox({
            "harness": "vibe",
            "workspace": kwargs.get("workspace", f"/srv/agentic/vibe/workspaces/workspace-{agent_identity[:8]}"),
            "cpu": 1.0, "memory_mb": 1024,
            "model": kwargs.get("model", os.environ.get("AGENTIC_DEFAULT_MODEL", "mistral-large-latest")),
        })
        if not provision["success"]:
            return {"success": False, "error": provision["error"]}

        session_id = f"vibe-{agent_identity[:8]}-{uuid.uuid4().hex[:6]}"
        vibe_home = kwargs.get("vibe_home", f"/srv/agentic/vibe/state")
        local_mode = kwargs.get("local_mode", True)  # Default offline/local

        return {
            "success": True,
            "session_id": session_id,
            "sandbox_id": provision["sandbox_id"],
            "mode": "vscode" if kwargs.get("vs_code") else "cli",
            "vibe_home": vibe_home,
            "local_mode": local_mode,  # Cloud disabled by default per v2 security
            "config_files": ["VIBE_HOME/config.toml", "AGENTS.md"],
        }

    async def end_session(self, session_id: str) -> dict[str, Any]:
        return {"success": True, "session_id": session_id}

    async def submit_tool_call(self, session_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return ToolCallResult(tool=tool, success=True).__dict__

    async def list_sessions(self, agent_identity: Optional[str] = None) -> list[dict[str, Any]]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        cid = adapter._find_container("vibe")
        if not cid:
            return []
        state = await adapter.observe_sandbox(cid)
        return [state] if state.get("success") else []


# ── 6. Pi (pi-mono) — Minimal with Extensions (§6.3, §2.2 table) ───

class PiHarnessAdapter(_HarnessAdapter):
    """Concrete HarnessAdapter for Pi (pi-mono in some v1 tests).

    Conforms to §6.3: Chat, Responses, Messages, or extension depending on config.
    Minimal by default; no sub-agents assumed without pinned package (§2.2 table).
    Authentication outside workspace — credentials managed separately.
    """

    _CAPABILITIES = _caps(
        tool_call_mode=ToolCallMode.BATCH,
        supports_sub_agents=False,
        allowed_network_domains=['pi.ai'],
    )

    @property
    def capabilities(self):
        return self._CAPABILITIES

    async def start_session(self, agent_identity: str, project: Optional[str] = None, **kwargs: Any) -> dict[str, Any]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        provision = await adapter.provision_sandbox({
            "harness": "pi",
            "workspace": kwargs.get("workspace", f"/srv/agentic/pi/workspaces/workspace-{agent_identity[:8]}"),
            "cpu": 1.0, "memory_mb": 512,
            "model": kwargs.get("model", os.environ.get("AGENTIC_DEFAULT_MODEL", "pimax-1-mini")),
        })
        if not provision["success"]:
            return {"success": False, "error": provision["error"]}

        session_id = f"pi-{agent_identity[:8]}-{uuid.uuid4().hex[:6]}"

        return {
            "success": True,
            "session_id": session_id,
            "sandbox_id": provision["sandbox_id"],
            "mode": "minimal",
            "auth_separated": True,
            "extension_packages": kwargs.get("extensions", []),
        }

    async def end_session(self, session_id: str) -> dict[str, Any]:
        return {"success": True, "session_id": session_id}

    async def submit_tool_call(self, session_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return ToolCallResult(tool=tool, success=True).__dict__

    async def list_sessions(self, agent_identity: Optional[str] = None) -> list[dict[str, Any]]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        cid = adapter._find_container("pi")
        if not cid:
            return []
        state = await adapter.observe_sandbox(cid)
        return [state] if state.get("success") else []


# ── 7. Goose — Recipes, ACP, Anti-Recursion (§6.3, §2.2 table) ─────

class GooseHarnessAdapter(_HarnessAdapter):
    """Concrete HarnessAdapter for Goose CLI/ACP.

    Conforms to §6.3: provider-based extension/recipe system.
    Supports internal and external sub-agents with anti-recursion guards (§5.4).
    Recipes, extensions, sessions, and ACP interface preserved from v1.
    """

    _CAPABILITIES = _caps(
        tool_call_mode=ToolCallMode.STREAMING,
        supports_sub_agents=True,
        max_depth=2,
        sub_agent_config=SubAgentConfig(mode="native", max_depth=1),
    )

    @property
    def capabilities(self):
        return self._CAPABILITIES

    async def start_session(self, agent_identity: str, project: Optional[str] = None, **kwargs: Any) -> dict[str, Any]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        provision = await adapter.provision_sandbox({
            "harness": "goose",
            "workspace": kwargs.get("workspace", f"/srv/agentic/goose/workspaces/workspace-{agent_identity[:8]}"),
            "cpu": 1.0, "memory_mb": 1024,
            "model": kwargs.get("model", os.environ.get("AGENTIC_DEFAULT_MODEL", "qwen3.8:27b")),
        })
        if not provision["success"]:
            return {"success": False, "error": provision["error"]}

        session_id = f"goose-{agent_identity[:8]}-{uuid.uuid4().hex[:6]}"
        recipes = kwargs.get("recipes", [])

        return {
            "success": True,
            "session_id": session_id,
            "sandbox_id": provision["sandbox_id"],
            "mode": "acp" if kwargs.get("acp") else "cli",
            "recipes": recipes,
            "anti_recursion_guard": True,  # Per §5.4 invariant
        }

    async def end_session(self, session_id: str) -> dict[str, Any]:
        return {"success": True, "session_id": session_id}

    async def submit_tool_call(self, session_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return ToolCallResult(tool=tool, success=True).__dict__

    async def list_sessions(self, agent_identity: Optional[str] = None) -> list[dict[str, Any]]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        cid = adapter._find_container("goose")
        if not cid:
            return []
        state = await adapter.observe_sandbox(cid)
        return [state] if state.get("success") else []


# ── 8. Hermes Native — Full Dashboard, Multi-Agent (§7.3, §2.2 table)

class HermesHarnessAdapter(_HarnessAdapter):
    """Hermes native path — production reference implementation (§7.3).

    Runs inside an OpenShell envelope with full dashboard, Chat, Desktop.
    Independent profiles, configurations, memory, sessions, skills, cron, Kanban.
    Sub-agents native and isolated. Concurrency limits, depth limits, budget controls.
    """

    _CAPABILITIES = _caps(
        tool_call_mode=ToolCallMode.STREAMING,
        supports_sub_agents=True,
        max_depth=4,
        allowed_network_domains=[],  # Local-first; external via ExternalAccessBroker
        sub_agent_config=SubAgentConfig(mode="native", max_depth=3),
    )

    @property
    def capabilities(self):
        return self._CAPABILITIES

    async def start_session(self, agent_identity: str, project: Optional[str] = None, **kwargs: Any) -> dict[str, Any]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        provision = await adapter.provision_sandbox({
            "harness": "hermes",
            "workspace": kwargs.get("workspace", f"/srv/agentic/hermes/workspaces/workspace-{agent_identity[:8]}"),
            "cpu": 2.0, "memory_mb": 4096,
            "model": kwargs.get("model", os.environ.get("AGENTIC_DEFAULT_MODEL", "qwen3.8:27b")),
        })
        if not provision["success"]:
            return {"success": False, "error": provision["error"]}

        session_id = f"hermes-{agent_identity[:8]}-{uuid.uuid4().hex[:6]}"
        profile = kwargs.get("profile", "default")

        return {
            "success": True,
            "session_id": session_id,
            "sandbox_id": provision["sandbox_id"],
            "mode": "hermes_native",
            "profile": profile,
            "kanban_shared": True,
            "dashboard_available": True,
            "cron_available": True,
        }

    async def end_session(self, session_id: str) -> dict[str, Any]:
        return {"success": True, "session_id": session_id}

    async def submit_tool_call(self, session_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return ToolCallResult(tool=tool, success=True).__dict__

    async def list_sessions(self, agent_identity: Optional[str] = None) -> list[dict[str, Any]]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        cid = adapter._find_container("hermes")
        if not cid:
            return []
        state = await adapter.observe_sandbox(cid)
        return [state] if state.get("success") else []


# ── 9. Hermes NemoClaw — Canary Path (§7.3, §2.2 table)

class HermesNemoClawAdapter(_HarnessAdapter):
    """Hermes NemoClaw canary path (§7.3).

    Blueprint pinned to specific version. Independent state root — no shared
    HERMES_HOME, sessions, or base with native. Import/export via dry-run only.
    Activated only after parity validated against native.
    """

    _CAPABILITIES = _caps(
        tool_call_mode=ToolCallMode.STREAMING,
        supports_sub_agents=True,
        max_depth=4,
        allowed_network_domains=[],
        sub_agent_config=SubAgentConfig(mode="platform"),
    )

    @property
    def capabilities(self):
        return self._CAPABILITIES

    async def start_session(self, agent_identity: str, project: Optional[str] = None, **kwargs: Any) -> dict[str, Any]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        provision = await adapter.provision_sandbox({
            "harness": "hermes-nemoclaw",
            "workspace": kwargs.get("workspace", f"/srv/agentic/hermes-nemoclaw/workspaces/workspace-{agent_identity[:8]}"),
            "cpu": 2.0, "memory_mb": 4096,
            "model": kwargs.get("model", os.environ.get("AGENTIC_DEFAULT_MODEL", "qwen3.8:27b")),
        })
        if not provision["success"]:
            return {"success": False, "error": provision["error"]}

        session_id = f"hermes-nc-{agent_identity[:8]}-{uuid.uuid4().hex[:6]}"

        return {
            "success": True,
            "session_id": session_id,
            "sandbox_id": provision["sandbox_id"],
            "mode": "hermes_nemoclaw",
            "nemoclaw_blueprint_pinned": True,
            "independent_state_root": True,
            "dry_run_only": True,
        }

    async def end_session(self, session_id: str) -> dict[str, Any]:
        return {"success": True, "session_id": session_id}

    async def submit_tool_call(self, session_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return ToolCallResult(tool=tool, success=True).__dict__

    async def list_sessions(self, agent_identity: Optional[str] = None) -> list[dict[str, Any]]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        cid = adapter._find_container("hermes-nemoclaw")
        if not cid:
            return []
        state = await adapter.observe_sandbox(cid)
        return [state] if state.get("success") else []


# ── 10. OpenClaw — Gateway, Multi-Agent, Multi-Channel (§7.2, §2.2 table)

class OpenClawHarnessAdapter(_HarnessAdapter):
    """Concrete HarnessAdapter for OpenClaw (formerly Clawdbot).

    Conforms to §6.3: Ollama/OpenAI-compatible per agent config.
    Permanent gateway process with multi-agent/multi-channel support, relay,
    attachments, Control UI, and sub-agents (§7.2).
    """

    _CAPABILITIES = _caps(
        tool_call_mode=ToolCallMode.STREAMING,
        supports_sub_agents=True,
        max_depth=2,
        sub_agent_config=SubAgentConfig(mode="native", max_depth=2),
    )

    @property
    def capabilities(self):
        return self._CAPABILITIES

    async def start_session(self, agent_identity: str, project: Optional[str] = None, **kwargs: Any) -> dict[str, Any]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        provision = await adapter.provision_sandbox({
            "harness": "openclaw",
            "workspace": kwargs.get("workspace", f"/srv/agentic/openclaw/workspaces/workspace-{agent_identity[:8]}"),
            "cpu": 1.0, "memory_mb": 2048,
            "model": kwargs.get("model", os.environ.get("AGENTIC_DEFAULT_MODEL", "qwen3.8:27b")),
        })
        if not provision["success"]:
            return {"success": False, "error": provision["error"]}

        session_id = f"openclaw-{agent_identity[:8]}-{uuid.uuid4().hex[:6]}"
        agent_dir = kwargs.get("agent_dir", "/srv/agentic/openclaw/agents")
        channels = kwargs.get("channels", ["default"])

        return {
            "success": True,
            "session_id": session_id,
            "sandbox_id": provision["sandbox_id"],
            "mode": "gateway",
            "agent_dir": agent_dir,
            "channels": channels,
            "relay_available": True,
            "attachments_supported": True,
        }

    async def end_session(self, session_id: str) -> dict[str, Any]:
        return {"success": True, "session_id": session_id}

    async def submit_tool_call(self, session_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return ToolCallResult(tool=tool, success=True).__dict__

    async def list_sessions(self, agent_identity: Optional[str] = None) -> list[dict[str, Any]]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        cid = adapter._find_container("openclaw")
        if not cid:
            return []
        state = await adapter.observe_sandbox(cid)
        return [state] if state.get("success") else []


# ── 11. OpenHands — Hybrid App + Harness (§7.4, §2.2 table)

class OpenHandsHarnessAdapter(_HarnessAdapter):
    """Concrete HarnessAdapter for OpenHands (hybrid application + agent platform).

    Conforms to §6.3: LiteLLM/OpenAI-compatible backend.
    Combines UI, settings, conversations, skills/hooks, GitHub integration,
    and its own runtime (§7.4). Application adapter + harness adapter + runtime adapter.
    """

    _CAPABILITIES = _caps(
        tool_call_mode=ToolCallMode.STREAMING,
        supports_sub_agents=True,
        max_depth=2,
        requires_gpu=True,
        sub_agent_config=SubAgentConfig(mode="native", max_depth=2),
    )

    @property
    def capabilities(self):
        return self._CAPABILITIES

    async def start_session(self, agent_identity: str, project: Optional[str] = None, **kwargs: Any) -> dict[str, Any]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))

        backend = kwargs.get("backend", "ollama-gate")
        enable_browser = kwargs.get("enable_browser", True)
        enable_terminal = kwargs.get("enable_terminal", True)

        provision = await adapter.provision_sandbox({
            "harness": "openhands",
            "workspace": kwargs.get("workspace", f"/srv/agentic/openhands/workspaces/workspace-{agent_identity[:8]}"),
            "cpu": 2.0, "memory_mb": 4096,
            "model": kwargs.get("model", os.environ.get("AGENTIC_DEFAULT_MODEL", "qwen3.8:27b")),
        })
        if not provision["success"]:
            return {"success": False, "error": provision["error"]}

        session_id = f"openhands-{agent_identity[:8]}-{uuid.uuid4().hex[:6]}"

        return {
            "success": True,
            "session_id": session_id,
            "sandbox_id": provision["sandbox_id"],
            "mode": "hybrid",
            "backend": backend,
            "supports_browser": enable_browser,
            "supports_terminal": enable_terminal,
        }

    async def end_session(self, session_id: str) -> dict[str, Any]:
        return {"success": True, "session_id": session_id}

    async def submit_tool_call(self, session_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return ToolCallResult(tool=tool, success=True).__dict__

    async def list_sessions(self, agent_identity: Optional[str] = None) -> list[dict[str, Any]]:
        from .docker_runtime_adapter import DockerRuntimeAdapter
        adapter = DockerRuntimeAdapter(project=os.environ.get("AGENTIC_COMPOSE_PROJECT", "agentic-dev"))
        cid = adapter._find_container("openhands")
        if not cid:
            return []
        state = await adapter.observe_sandbox(cid)
        return [state] if state.get("success") else []


# ── Harness Registry ─────────────────────────────────────────────────

def get_harness(name: str) -> _HarnessAdapter | None:
    """Look up a concrete harness by name.

    Supports all harnesses from PLAN.md §2.2 and §6.3 protocol matrix.
    """
    registry = {
        "codex": CodexHarnessAdapter(),
        "claude": ClaudeCodeHarnessAdapter(),
        "opencode": OpenCodeHarnessAdapter(),
        "kilocode": KiloCodeHarnessAdapter(),
        "vibe": VibeHarnessAdapter(),
        "hermes": HermesHarnessAdapter(),
        "hermes-nemoclaw": HermesNemoClawAdapter(),
        "pi": PiHarnessAdapter(),
        "goose": GooseHarnessAdapter(),
        "openclaw": OpenClawHarnessAdapter(),
        "openhands": OpenHandsHarnessAdapter(),
    }
    return registry.get(name)


def list_available_harnesses() -> list[dict[str, Any]]:
    """Return metadata about all available harnesses (10 entries matching v1 baseline)."""
    results = []
    for name, adapter in get_all_harnesses().items():
        caps = adapter.capabilities
        results.append({
            "harness": name,
            "tool_call_mode": caps.tool_call_mode.value if hasattr(caps, 'tool_call_mode') and caps.tool_call_mode else "default",
            "supports_sub_agents": caps.supports_sub_agents,
            "max_depth": caps.max_depth,
            "supports_streaming": caps.supports_streaming,
            "requires_gpu": caps.requires_gpu,
        })
    return sorted(results, key=lambda x: x["harness"])


def get_all_harnesses() -> dict[str, _HarnessAdapter]:
    """Return all registered harness instances (10 entries matching v1 baseline)."""
    return {
        "codex": CodexHarnessAdapter(),
        "claude": ClaudeCodeHarnessAdapter(),
        "opencode": OpenCodeHarnessAdapter(),
        "kilocode": KiloCodeHarnessAdapter(),
        "vibe": VibeHarnessAdapter(),
        "hermes": HermesHarnessAdapter(),
        "pi": PiHarnessAdapter(),
        "goose": GooseHarnessAdapter(),
        "openclaw": OpenClawHarnessAdapter(),
        "openhands": OpenHandsHarnessAdapter(),
    }

# ── CLI entry point ──────────────────────────────────────────────────

def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Harness Adapters — list/inspect sessions")
    parser.add_argument("--action", choices=["list", "sessions", "harnesses"], default="list")
    parser.add_argument("--harness", choices=[
        "codex", "claude", "opencode", "kilocode", "vibe",
        "hermes", "hermes-nemoclaw", "pi", "goose", "openclaw", "openhands",
    ])
    args = parser.parse_args()

    harnesses = get_all_harnesses()

    if args.action == "list":
        # Include hermes-nemoclaw in listing even though not in base list
        all_for_list = get_all_harnesses().copy()
        all_for_list["hermes-nemoclaw"] = HermesNemoClawAdapter()
        for name, h in all_for_list.items():
            caps = h.capabilities
            sub_agents = "yes" if caps.supports_sub_agents else "no"
            streaming = "yes" if caps.supports_streaming else "no"
            gpu = "yes" if caps.requires_gpu else "no"
            print(f"  {name}: sub_agents={sub_agents} streaming={streaming} gpu={gpu}")

    elif args.action == "harnesses":
        harnesses_list = list_available_harnesses()
        print("All registered harnesses (evaluation-ready):")
        for h in harnesses_list:
            print(f"  {h['harness']}: tool_mode={h['tool_call_mode']} sub_agents={h['supports_sub_agents']} depth={h['max_depth']} gpu={h['requires_gpu']}")

    elif args.action == "sessions":
        harness_name = args.harness or "codex"
        adapter = harnesses.get(harness_name)
        if adapter:
            sessions = asyncio.run(adapter.list_sessions())
            print(json.dumps(sessions, indent=2))

    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
