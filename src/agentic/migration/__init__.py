"""Migration router for v1 → v2 capability routing (§13).

Provides:
- CapabilityRegistry: maps command_ids to version-specific route entries
- CommandRoute: single command with {version → RouteVersion} mappings
- RouteVersion: V1 | V2 | HYBRID
- resolve_and_run(command_id, context): routes to the correct implementation

Usage:
    from agentic.migration import create_default_routes
    
    registry = create_default_routes()
    route = registry.get_route("codex_session")
"""

from .router import (
    CapabilityRegistry,
    CommandRoute,
    RouteVersion,
    create_default_routes,
    resolve_and_run,
)

__all__ = [
    "CapabilityRegistry",
    "CommandRoute",
    "RouteVersion",
    "create_default_routes",
    "resolve_and_run",
]
