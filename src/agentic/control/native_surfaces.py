#!/usr/bin/env python3
"""src/agentic/control/native_surfaces.py - Section 9.4 Native Surfaces URL/Tunnel configuration.

Manages the official URLs, tunnels, and proxies for native application surfaces:
- Hermes Dashboard et Desktop
- OpenHands UI  
- Kilo CLI/IDE/console
- Vibe CLI/VS Code/ACP
- Goose ACP
- OpenWebUI, ComfyUI, Forgejo, Grafana
- DGX Dashboard, JupyterLab

Per Section 9.4: No iframe or reverse proxy sub-path is assumed compatible without proof.
The portal uses an official URL, tunnel, or proxy.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Optional


class SurfaceAccessMethod(enum.Enum):
    DIRECT_URL = "direct_url"
    TAILSCALE_TUNNEL = "tailscale_tunnel"
    SSH_FORWARD = "ssh_forward"
    PROXY = "proxy"


class SurfaceCategory(enum.Enum):
    AGENT_DASHBOARD = "agent_dashboard"
    CLI_CONSOLE = "cli_console"
    WEB_APP = "web_app"
    DESKTOP = "desktop"


@dataclass
class SurfaceConfig:
    name: str
    url: Optional[str] = None
    access_method: SurfaceAccessMethod = SurfaceAccessMethod.DIRECT_URL
    category: SurfaceCategory = SurfaceCategory.WEB_APP
    approved_tunnel_hosts: list[str] = field(default_factory=list)
    proxy_path: Optional[str] = None
    validated: bool = False
    validation_note: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "url": self.url,
            "access_method": self.access_method.value,
            "category": self.category.value,
            "approved_tunnel_hosts": self.approved_tunnel_hosts,
            "proxy_path": self.proxy_path,
            "validated": self.validated,
            "validation_note": self.validation_note,
        }


class NativeSurfaceRegistry:
    """Registry and validator for native surface configurations (Section 9.4)."""

    DEFAULT_SURFACES: dict[str, SurfaceConfig] = {
        "hermes_dashboard": SurfaceConfig(
            name="hermes_dashboard", category=SurfaceCategory.AGENT_DASHBOARD,
            url="http://127.0.0.1:3456", validated=False, validation_note="Requires hardware validation",
        ),
        "openhands_ui": SurfaceConfig(
            name="openhands_ui", category=SurfaceCategory.AGENT_DASHBOARD,
            url="http://127.0.0.1:3000", validated=False, validation_note="Requires hardware validation",
        ),
        "kilo_cli": SurfaceConfig(name="kilo_cli", category=SurfaceCategory.CLI_CONSOLE,
                                  validated=False, validation_note="CLI-based surface"),
        "vibe_cli": SurfaceConfig(name="vibe_cli", category=SurfaceCategory.CLI_CONSOLE,
                                  validated=False, validation_note="CLI-based surface"),
        "goose_acp": SurfaceConfig(name="goose_acp", category=SurfaceCategory.CLI_CONSOLE,
                                   validated=False, validation_note="Requires hardware validation"),
        "openwebui": SurfaceConfig(name="openwebui", category=SurfaceCategory.WEB_APP,
                                   url="http://127.0.0.1:8080", validated=False,
                                   validation_note="Requires docker-compose runtime validation"),
        "comfyui": SurfaceConfig(name="comfyui", category=SurfaceCategory.WEB_APP,
                                 url="http://127.0.0.1:8188", validated=False,
                                 validation_note="Requires docker-compose runtime validation"),
        "forgejo": SurfaceConfig(name="forgejo", category=SurfaceCategory.WEB_APP,
                                 url="http://127.0.0.1:3001", validated=False,
                                 validation_note="Requires docker-compose runtime validation"),
        "grafana": SurfaceConfig(name="grafana", category=SurfaceCategory.WEB_APP,
                                 url="http://127.0.0.1:3002", validated=False,
                                 validation_note="Requires docker-compose runtime validation"),
        "hermes_desktop": SurfaceConfig(name="hermes_desktop", category=SurfaceCategory.DESKTOP,
                                        validated=False, validation_note="Requires hardware validation"),
        "vibe_vscode": SurfaceConfig(name="vibe_vscode", category=SurfaceCategory.DESKTOP,
                                     validated=False, validation_note="Requires hardware validation"),
        "dgx_dashboard": SurfaceConfig(name="dgx_dashboard", category=SurfaceCategory.WEB_APP,
                                       validated=False, validation_note="Requires NVIDIA DGX hardware"),
        "jupyterlab": SurfaceConfig(name="jupyterlab", category=SurfaceCategory.WEB_APP,
                                    url="http://127.0.0.1:8888", validated=False,
                                    validation_note="Requires docker-compose runtime validation"),
    }

    def __init__(self):
        self._surfaces: dict[str, SurfaceConfig] = {}
        for name, config in self.DEFAULT_SURFACES.items():
            self._surfaces[name] = config

    def get_surface(self, name: str) -> Optional[SurfaceConfig]:
        return self._surfaces.get(name)

    def list_all(self) -> dict[str, SurfaceConfig]:
        return self._surfaces.copy()

    def configure_surface(self, name: str, config: SurfaceConfig) -> bool:
        self._surfaces[name] = config
        return True

    def validate_access_method(self, name: str, requested_method: str) -> tuple[bool, str]:
        surface = self._surfaces.get(name)
        if not surface:
            return False, f"Unknown surface: {name}"
        try:
            method = SurfaceAccessMethod(requested_method)
        except ValueError:
            return False, f"Invalid access method. Allowed: {[m.value for m in SurfaceAccessMethod]}"
        if method in [SurfaceAccessMethod.DIRECT_URL, SurfaceAccessMethod.TAILSCALE_TUNNEL]:
            if surface.url and not (surface.url.startswith("http://") or surface.url.startswith("https://")):
                return False, f"URL must start with http(s)://"
        if method == SurfaceAccessMethod.PROXY:
            if surface.proxy_path and not surface.proxy_path.startswith("/"):
                return False, "Proxy path must start with /"
        return True, "ok"

    def mark_validated(self, name: str, note: str = "") -> tuple[bool, str]:
        surface = self._surfaces.get(name)
        if not surface:
            return False, f"Unknown surface: {name}"
        surface.validated = True
        surface.validation_note = note or datetime.now(timezone.utc).isoformat()
        return True, "ok"

    def compliance_report(self) -> dict[str, Any]:
        all_surfaces = self._surfaces
        total = len(all_surfaces)
        validated = sum(1 for s in all_surfaces.values() if s.validated)
        by_category: dict[str, list[str]] = {}
        for name, config in all_surfaces.items():
            cat = config.category.value
            by_category.setdefault(cat, []).append(name)
        return {
            "total_surfaces": total,
            "validated_count": validated,
            "unvalidated_count": total - validated,
            "compliance_pct": round(validated / total * 100, 1) if total > 0 else 0,
            "by_category": by_category,
            "surfaces": {name: config.to_dict() for name, config in all_surfaces.items()},
        }


_native_surface_registry = NativeSurfaceRegistry()

def get_registry() -> NativeSurfaceRegistry:
    return _native_surface_registry

if __name__ == "__main__":
    reg = get_registry()
    report = reg.compliance_report()
    print(f"Native surfaces: {report['total_surfaces']}")
    print(f"Validated: {report['validated_count']}")
    print(f"Compliance: {report['compliance_pct']}%")
