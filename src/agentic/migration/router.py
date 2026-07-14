#!/usr/bin/env python3
"""src/agentic/migration/router.py — v1/v2 capability router (§13.1).

Routes agent commands and API calls to v1 or v2 implementations based on:
- Capability identifier
- Enabled routes per user, agent, project, and capability
- Stable JSON output contracts
- Compatibility exit codes
- Removal conditions for deprecated v1 routes

This router acts as the facade during transition. Each command maps to
a versioned handler registry. The `agent` CLI shell wrapper delegates to
this module for structured capability routing.
"""

from __future__ import annotations

import enum
import json
import sys
from dataclasses import dataclass, field
from typing import Any, Callable, Optional


class RouteVersion(enum.Enum):
    V1 = "v1"
    V2 = "v2"
    HYBRID = "hybrid"


@dataclass(frozen=True)
class CommandRoute:
    """Routing metadata for a single capability/command."""
    command_id: str
    version_routes: dict[str, RouteVersion]  # e.g., {"default": V1, "codex": V2}
    json_output_format: Optional[str] = None  # stable schema ID
    exit_codes: dict[str, int] = field(default_factory=dict)  # v1=v0, v2=0
    parity_test_script: Optional[str] = None
    removal_condition: str = ""  # when to deprecate v1 route

    def resolve(self, user_id: Optional[str] = None, agent: Optional[str] = None, project: Optional[str] = None) -> RouteVersion:
        """Determine which version route to use based on context."""
        if agent and agent in self.version_routes:
            return self.version_routes[agent]
        if user_id and f"user_{user_id}" in self.version_routes:
            return self.version_routes[f"user_{user_id}"]
        if project and f"project_{project}" in self.version_routes:
            return self.version_routes[f"project_{project}"]
        return self.version_routes.get("default", RouteVersion.HYBRID)


@dataclass
class CapabilityRegistry:
    """Central registry of v1/v2 command routes."""

    _routes: dict[str, CommandRoute] = field(default_factory=dict)

    def register(self, route: CommandRoute) -> None:
        self._routes[route.command_id] = route

    def get_route(self, command_id: str) -> Optional[CommandRoute]:
        return self._routes.get(command_id)

    def list_all(self) -> dict[str, CommandRoute]:
        return self._routes.copy()


# ── Default Routes (§13.1) ──────────────────────────────────────────────
def create_default_routes() -> CapabilityRegistry:
    """Initialize default routing table for core v2 capabilities."""
    registry = CapabilityRegistry()

    # Bootstrap & infrastructure
    registry.register(CommandRoute(
        command_id="bootstrap",
        version_routes={"default": RouteVersion.V2},
        json_output_format="agentic.bootstrap.v1",
        exit_codes={"v1": 0, "v2": 0},
        parity_test_script="tests/A1_host_prereqs.sh",
    ))

    registry.register(CommandRoute(
        command_id="up",
        version_routes={"default": RouteVersion.HYBRID},
        json_output_format="agentic.compose.up.v1",
        exit_codes={"v1": 0, "v2": 0},
        parity_test_script="tests/L2_stack_stepwise.sh",
    ))

    registry.register(CommandRoute(
        command_id="doctor",
        version_routes={"default": RouteVersion.V2},
        json_output_format="agentic.doctor.v1",
        exit_codes={"v1": 0, "v2": 0},
        parity_test_script="tests/F3_doctor.sh",
    ))

    # Agent harnesses (M6)
    registry.register(CommandRoute(
        command_id="agent.start.codex",
        version_routes={"default": RouteVersion.V2, "agentic-dev": RouteVersion.V1},
        json_output_format="agentic.session.v1",
        exit_codes={"v1": 0, "v2": 0},
        parity_test_script="tests/L7_default_model_tool_call_fs_ops.sh",
    ))

    registry.register(CommandRoute(
        command_id="agent.start.claude",
        version_routes={"default": RouteVersion.V2},
        json_output_format="agentic.session.v1",
        exit_codes={"v1": 0, "v2": 0},
    ))

    # Model routing (M5)
    registry.register(CommandRoute(
        command_id="model.route",
        version_routes={"default": RouteVersion.V2},
        json_output_format="agentic.model.broker.v1",
        parity_test_script="tests/D8_gate_protocol_compat.sh",
    ))

    # RAG (M9)
    registry.register(CommandRoute(
        command_id="rag.submit",
        version_routes={"default": RouteVersion.V2},
        json_output_format="agentic.rag.task.v1",
        parity_test_script="tests/J3_rag_schema.sh",
    ))

    # Update & rollback (M4/M7)
    registry.register(CommandRoute(
        command_id="update",
        version_routes={"default": RouteVersion.V2},
        json_output_format="agentic.release.snapshot.v1",
        exit_codes={"v1": 0, "v2": 0},
        parity_test_script="tests/F2_update_rollback.sh",
    ))

    registry.register(CommandRoute(
        command_id="rollback",
        version_routes={"default": RouteVersion.V2},
        json_output_format="agentic.rollback.v1",
        exit_codes={"v1": 0, "v2": 0},
        parity_test_script="tests/F17_rollback_artifact_hermetic.sh",
    ))

    # ── Infrastructure & Exploitation (Section 2.1) ────────────────
    # These commands are preserved from v1 but may have v2 implementations
    
    registry.register(CommandRoute(
        command_id="down",
        version_routes={"default": RouteVersion.HYBRID},
        json_output_format="agentic.compose.down.v1",
        exit_codes={"v1": 0, "v2": 0},
        parity_test_script="tests/L3_cleanup.sh",
    ))
    
    registry.register(CommandRoute(
        command_id="ls",
        version_routes={"default": RouteVersion.HYBRID},
        json_output_format="agentic.container.list.v1",
        exit_codes={"v1": 0, "v2": 0},
        parity_test_script="tests/L1_stop_resources.sh",
    ))
    
    registry.register(CommandRoute(
        command_id="ps",
        version_routes={"default": RouteVersion.HYBRID},
        json_output_format="agentic.container.status.v1",
        exit_codes={"v1": 0, "v2": 0},
        parity_test_script="tests/L1_stop_resources.sh",
    ))
    
    registry.register(CommandRoute(
        command_id="status",
        version_routes={"default": RouteVersion.HYBRID},
        json_output_format="agentic.stack.status.v1",
        exit_codes={"v1": 0, "v2": 0},
        parity_test_script="tests/F3_doctor.sh",
    ))
    
    registry.register(CommandRoute(
        command_id="logs",
        version_routes={"default": RouteVersion.HYBRID},
        json_output_format="agentic.container.logs.v1",
        exit_codes={"v1": 0, "v2": 0},
    ))
    
    registry.register(CommandRoute(
        command_id="backup",
        version_routes={"default": RouteVersion.V2},
        json_output_format="agentic.backup.snapshot.v1",
        parity_test_script="tests/F8_backup_incremental.sh",
    ))
    
    registry.register(CommandRoute(
        command_id="restore",
        version_routes={"default": RouteVersion.V2},
        json_output_format="agentic.restore.recovery.v1",
        exit_codes={"v1": 0, "v2": 0},
        parity_test_script="tests/F9_first_up_command.sh",
    ))
    
    registry.register(CommandRoute(
        command_id="cleanup",
        version_routes={"default": RouteVersion.HYBRID},
        json_output_format="agentic.cleanup.state.v1",
        parity_test_script="tests/L3_cleanup.sh",
    ))
    
    registry.register(CommandRoute(
        command_id="snapshot",
        version_routes={"default": RouteVersion.V2},
        json_output_format="agentic.release.snapshot.v1",
        exit_codes={"v1": 0, "v2": 0},
        parity_test_script="tests/F5_auto_release_manifest.sh",
    ))

    return registry


# ── Router Execution Stub ───────────────────────────────────────────────
def resolve_and_run(
    command_id: str,
    args: list[str],
    user_id: Optional[str] = None,
    agent_name: Optional[str] = None,
    project: Optional[str] = None,
) -> int:
    """Resolve route and execute (stub).

    In a full implementation this dispatches to the appropriate v1/v2 handler.
    For now it validates routing exists and prints the resolved version.
    """
    routes = create_default_routes()
    route = routes.get_route(command_id)

    if not route:
        print(f"ERROR: no route for command '{command_id}'", file=sys.stderr)
        return 1

    resolved_version = route.resolve(user_id=user_id, agent=agent_name, project=project)
    print(f"ROUTED: {command_id} -> {resolved_version.value}", file=sys.stderr)

    # If JSON output is expected, structure it
    if route.json_output_format:
        return 0  # success in router validation

    return 0
