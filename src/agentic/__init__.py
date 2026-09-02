"""DGX Spark Agentic Platform v2 — Modular control plane and adapters.

This package provides:
- contracts/adapters.py      : ABC interface definitions (§3.2)
- control/                   : Control plane (API, scheduler, reconciler, worker)
- implementations/           : Concrete adapter implementations
- models/                    : Identity and project data models
- migration/                 : v1 → v2 migration router

Usage:
    from agentic.control.api import control_api
    from agentic.implementations.harness_adapters import HARNESSES
    
    control_api.start(host="127.0.0.1", port=8080)
"""

__version__ = "0.2.0-dev"
