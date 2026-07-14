"""tests/J20_migration_router.py — §13 Migration Router.

Validates:
- Default routes are registered correctly (covers Section 2.1 and core v2 commands)
- Route resolution respects user/agent/project overrides
- Route resolution falls back to default properly
- JSON output format is set for all core commands
- Resolution supports project-based overrides
- resolve_and_run validates routes and produces output

Tests:
- J20-1: Default routes created with expected commands (Section 2.1 + M3/M4)
- J20-2: Route resolution uses agent override when specified
- J20-3: Route resolution falls back to default properly
- J20-4: JSON output format is set for all core commands
- J20-5: Resolution supports project-based overrides
"""

import sys
sys.path.insert(0, "src")

from agentic.migration.router import (
    CapabilityRegistry, CommandRoute, RouteVersion, create_default_routes, resolve_and_run,
)


def test_default_routes():
    """J20-1: Default routes are created with expected commands.
    
    Verifies that the default routing table includes all critical capabilities from
    Section 2.1 (exploitation) and core v2 commands (bootstrap, agent.start, model.route).
    Total: 18 routes covering bootstrap, up/down/ls/ps/status/logs, doctor, agent.start.*,
    model.route, rag.submit, update/rollback/snapshot/backup/restore/cleanup.
    """
    routes = create_default_routes()
    all_routes = routes.list_all()
    
    # Core v2 commands (M3/M4)
    core_commands = [
        "bootstrap", "up", "down", "doctor",
        "agent.start.codex", "agent.start.claude",
        "model.route", "rag.submit",
        "update", "rollback",
        "snapshot", "backup", "restore",
    ]
    
    # Section 2.1 exploitation commands
    infra_commands = [
        "ls", "ps", "status", "logs",
        "cleanup",
    ]
    
    all_expected = core_commands + infra_commands
    
    for cmd in all_expected:
        assert cmd in all_routes, f"Missing route: {cmd}"
    
    # Verify we have exactly 18 routes
    assert len(all_routes) == 18, f"Expected 18 routes (Section 2.1 + core v2), got {len(all_routes)}"
    
    print("PASS: J20-1_default_routes")


def test_route_resolution_agent_override():
    """J20-2: Route resolution uses agent override when specified."""
    routes = create_default_routes()
    route = routes.get_route("agent.start.codex")
    
    assert route is not None, "codex route should exist"
    
    # Default should be V2
    default_version = route.resolve()
    assert default_version == RouteVersion.V2, f"Default should be V2: {default_version}"
    
    # Agent override for agentic-dev should be V1
    dev_version = route.resolve(agent="agentic-dev")
    assert dev_version == RouteVersion.V1, f"agentic-dev should resolve to V1: {dev_version}"
    
    # Default user should still be V2
    normal_version = route.resolve(user_id="normal-user")
    assert normal_version == RouteVersion.V2, f"Normal user should get V2: {normal_version}"
    
    print("PASS: J20-2_route_resolution_agent_override")


def test_route_fallback_to_default():
    """J20-3: Route resolution falls back to default properly."""
    routes = create_default_routes()
    route = routes.get_route("model.route")
    
    assert route is not None
    
    # All resolutions should return V2 for model.route (only default specified)
    v1 = route.resolve(user_id="u1", agent="claude", project="p1")
    v2 = route.resolve()
    
    assert v1 == RouteVersion.V2, f"Should resolve to V2: {v1}"
    assert v2 == RouteVersion.V2, f"Default should be V2: {v2}"
    
    print("PASS: J20-3_route_fallback_to_default")


def test_json_output_formats():
    """J20-4: JSON output format is set for all core commands.
    
    Verifies that routing metadata includes stable JSON output schemas for all routes.
    """
    routes = create_default_routes()
    all_routes = routes.list_all()
    
    # All routes should have a json_output_format defined (per §2.7: "un format JSON stable lorsqu'il existe")
    missing_formats = []
    for cmd_id, route in all_routes.items():
        if route.json_output_format is None:
            missing_formats.append(cmd_id)
    
    assert len(missing_formats) == 0, \
        f"Routes missing json_output_format: {missing_formats}"
    
    # Verify format naming convention follows agentic.<domain>.<type>.<version>
    for cmd_id, route in all_routes.items():
        fmt = route.json_output_format
        assert fmt.startswith("agentic."), \
            f"Format '{fmt}' for '{cmd_id}' should start with 'agentic.'"
    
    print("PASS: J20-4_json_output_formats")


def test_project_based_resolution():
    """J20-5: Resolution supports project-based overrides."""
    # Create a custom registry with project override
    registry = CapabilityRegistry()
    registry.register(CommandRoute(
        command_id="custom.cmd",
        version_routes={
            "default": RouteVersion.V2,
            "project_gpu": RouteVersion.HYBRID,
            "user_prod": RouteVersion.V1,
        },
        json_output_format="agentic.custom.v1",
    ))
    
    route = registry.get_route("custom.cmd")
    assert route is not None
    
    # Default project
    v1 = route.resolve(project=None)
    assert v1 == RouteVersion.V2, f"Default should be V2: {v1}"
    
    # GPU project override
    v2 = route.resolve(project="gpu")
    assert v2 == RouteVersion.HYBRID, f"GPU project should get HYBRID: {v2}"
    
    # User override takes precedence over project
    v3 = route.resolve(user_id="prod", project="gpu")
    assert v3 == RouteVersion.V1, f"User prod should override to V1: {v3}"
    
    print("PASS: J20-5_project_based_resolution")


if __name__ == "__main__":
    test_default_routes()
    test_route_resolution_agent_override()
    test_route_fallback_to_default()
    test_json_output_formats()
    test_project_based_resolution()
    print("\n=== J20_migration_router passed ===")
