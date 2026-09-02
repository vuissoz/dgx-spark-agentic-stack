"""Concrete adapter implementations for v2 (§3.2, §6-§10).

Harness adapters (get_all_harnesses): Codex, ClaudeCode, OpenCode, KiloCode,
Vibe, Pi, Goose, Hermes, HermesNemoClaw, OpenClaw, OpenHands.

Application adapters: ComfyUI, OpenWebUI, Forgejo, Grafana, DGX Dashboard,
JupyterLab, Portainer.

Other: ModelBroker, GPUJobAdapter, RAG adapter, GitProviderAdapters,
ExternalAccessBroker (credential rotation + SecretStore), OpenShell driver.

Usage:
    from agentic.implementations import get_all_harnesses
    
    harnesses = get_all_harnesses()
"""

from .harness_adapters import (
    get_all_harnesses,
    list_available_harnesses,
)

__all__ = [
    "get_all_harnesses",
    "list_available_harnesses",
]
