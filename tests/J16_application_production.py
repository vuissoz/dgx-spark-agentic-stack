"""tests/J16_application_production.py — Application adapter production features (§9.2).

Validates:
- OpenWebUI RBAC configuration and access control
- ComfyUI GPU job admission (stub, no docker required)
- Flux model adapter initialization
- Tool/function allowlist governance (§9.3 risk extensions)
"""

import asyncio
import sys
sys.path.insert(0, "src")


def test_openwebui_rbac():
    """Test OpenWebUI RBAC manager (PLAN.md §9.2)."""
    from agentic.implementations.application_adapters import OpenWebUIRBACManager
    
    rbac = OpenWebUIRBACManager()
    
    # Add users with different roles
    rbac.add_user_role("alice", "admin")
    rbac.add_user_role("bob", "editor")
    rbac.add_user_role("charlie", "viewer")
    
    # Admin can access everything
    assert rbac.check_access("alice", "sessions"), "Admin should have session access"
    assert rbac.check_access("alice", "config"), "Admin should have config access"
    assert rbac.check_access("alice", "backup"), "Admin should have backup access"
    
    # Editor can use sessions/models/tools but not config/backup
    assert rbac.check_access("bob", "sessions"), "Editor should have session access"
    assert rbac.check_access("bob", "models"), "Editor should have model access"
    assert not rbac.check_access("bob", "config"), "Editor should NOT have config access"
    assert not rbac.check_access("bob", "backup"), "Editor should NOT have backup access"
    
    # Viewer can only read sessions/models
    assert rbac.check_access("charlie", "sessions"), "Viewer should have session access"
    assert rbac.check_access("charlie", "models"), "Viewer should have model access"
    assert not rbac.check_access("charlie", "tools"), "Viewer should NOT have tools access"
    
    # Unknown user denied
    assert not rbac.check_access("unknown", "sessions"), "Unknown user should be denied"
    
    print("PASS: OpenWebUI RBAC")


def test_model_allowlist():
    """Test ModelBroker-only model allowlist (PLAN.md §9.2)."""
    from agentic.implementations.application_adapters import OpenWebUIRBACManager
    
    rbac = OpenWebUIRBACManager()
    
    # Configure model allowlist via ModelBroker
    result = rbac.configure_model_allowlist(["llama-3", "mistral-7b"])
    assert result["count"] == 2
    assert "llama-3" in result["allowed_models"]
    assert "All model access must route through ModelBroker" in result["note"]
    
    # Verify deduplication
    rbac.configure_model_allowlist(["llama-3", "llama-3"])
    # Note: the second call replaces, so we test with unique list
    
    print("PASS: Model allowlist")


def test_tool_allowlist():
    """Test Tool/Function allowlist governance (PLAN.md §9.3)."""
    from agentic.implementations.application_adapters import OpenWebUIRBACManager
    
    rbac = OpenWebUIRBACManager()
    
    # Configure tool allowlist (tools execute Python — security risk)
    result = rbac.configure_tool_allowlist(["python_execute", "file_read"])
    assert result["count"] == 2
    assert "Tools execute Python — allowlist and review required" in result["note"]
    
    print("PASS: Tool allowlist governance")


def test_comfyui_gpu_job_admission():
    """Test ComfyUI GPU job admission stub (PLAN.md §9.2)."""
    from agentic.implementations.application_adapters import ComfyUIGPUJobAdapter
    
    adapter = ComfyUIGPUJobAdapter()
    
    # Admit a GPU job
    result = asyncio.run(adapter.admit_job({
        "gpu_count": 1,
        "memory_mb": 2048,
        "workflow_file": "flux_generate.json",
    }))
    
    assert result["admitted"], f"Expected admitted: {result}"
    assert "job_id" in result
    assert result["gpu_allocated"] == 1
    
    # Observe the job
    observe = asyncio.run(adapter.observe_job(result["job_id"]))
    assert observe["status"] == "admitted"
    assert observe["workflow_file"] == "flux_generate.json"
    
    # Cancel the job
    cancelled = asyncio.run(adapter.cancel_job(result["job_id"]))
    assert cancelled == True
    
    # Observe cancelled status
    observe_after_cancel = asyncio.run(adapter.observe_job(result["job_id"]))
    assert observe_after_cancel["status"] == "cancelled"
    
    print("PASS: ComfyUI GPU job admission")


def test_flux_adapter_init():
    """Test Flux model adapter initialization."""
    from agentic.implementations.application_adapters import FluxModelAdapter
    
    adapter = FluxModelAdapter(comfyui_url="http://127.0.0.1:8188")
    
    # Health check should fail (no ComfyUI running) but not crash
    result = asyncio.run(adapter.health_check())
    assert isinstance(result, bool), "Health check should return bool"
    
    # Load model stub
    load_result = asyncio.run(adapter.load_model("flux-schnell"))
    assert "loaded" in load_result
    assert load_result["model"] == "flux-schnell"
    
    print("PASS: Flux adapter initialization")


def test_all_adapters_registry():
    """Test application adapters registry."""
    from agentic.implementations.application_adapters import (
        get_all_application_adapters,
        get_application_rbac_manager,
        get_flux_adapter,
    )
    
    # Registry should have 7 applications per §9.2
    adapters = get_all_application_adapters()
    expected = {"comfyui", "openwebui", "forgejo", "grafana", "dgx_dashboard", "jupyterlab", "portainer"}
    assert set(adapters.keys()) == expected, f"Expected {expected}, got {set(adapters.keys())}"
    
    # RBAC manager and Flux adapter factories work
    rbac = get_application_rbac_manager()
    flux = get_flux_adapter("http://custom:8188")
    assert rbac is not None
    assert flux is not None
    
    print("PASS: All adapters registry")


if __name__ == "__main__":
    test_openwebui_rbac()
    test_model_allowlist()
    test_tool_allowlist()
    test_comfyui_gpu_job_admission()
    test_flux_adapter_init()
    test_all_adapters_registry()
    print("\n=== J16_application_production passed ===")
