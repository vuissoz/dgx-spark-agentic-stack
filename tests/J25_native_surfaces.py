"""tests/J25_native_surfaces.py - Section 9.4 Native Surfaces URL/Tunnel configuration tests.

Validates:
- Registry contains all 13 surfaces defined in Section 9.4
- URL validation enforces http(s):// format
- Access method validation accepts only approved methods
- Compliance report is structured correctly
- mark_validated updates surface state
- Categories are properly assigned

Tests:
- J25-1: Registry contains all expected surfaces from Section 9.4
- J25-2: URL validation enforces http/https protocol
- J25-3: Access method whitelist is enforced
- J25-4: Compliance report structure and accuracy
- J25-5: mark_validated updates surface state correctly
- J25-6: Categories are properly assigned per Section 9.4
"""

import sys
sys.path.insert(0, "src")

from agentic.control.native_surfaces import (
    NativeSurfaceRegistry, SurfaceConfig, 
    SurfaceAccessMethod, SurfaceCategory, get_registry,
)


def _make_reg():
    """Create a fresh registry instance for isolated tests."""
    return NativeSurfaceRegistry()


def test_registry_contains_expected_surfaces():
    """J25-1: Registry contains all expected surfaces from Section 9.4."""
    reg = _make_reg()
    
    # Section 9.4 lists these surfaces:
    expected_surfaces = [
        "hermes_dashboard", "hermes_desktop",
        "openhands_ui",
        "kilo_cli", "vibe_cli", "goose_acp",
        "openwebui", "comfyui", "forgejo", "grafana",
        "dgx_dashboard", "jupyterlab",
    ]
    
    all_surfaces = reg.list_all()
    
    for surface in expected_surfaces:
        assert surface in all_surfaces, f"Missing surface from Section 9.4: {surface}"
    
    # Also verify no unexpected surfaces (exactly 13 as listed)
    assert len(all_surfaces) == 13, \
        f"Expected 13 surfaces per Section 9.4, got {len(all_surfaces)}"
    
    print("PASS: J25-1_registry_contains_expected_surfaces")


def test_url_validation_enforces_protocol():
    """J25-2: URL validation enforces http/https protocol."""
    reg = _make_reg()
    
    # Test with normal openwebui surface (has valid http:// URL)
    ok, reason = reg.validate_access_method("openwebui", "direct_url")
    assert ok, f"Should allow direct_url: {reason}"
    
    ok2, reason2 = reg.validate_access_method("comfyui", "tailscale_tunnel")
    assert ok2, f"Should allow tailscale_tunnel: {reason2}"
    
    # Test with a custom surface that has an invalid URL
    bad_surface = SurfaceConfig(
        name="bad-surface", category=SurfaceCategory.WEB_APP, url="ftp://evil.com/app"
    )
    reg.configure_surface("bad-surface", bad_surface)
    ok3, reason3 = reg.validate_access_method("bad-surface", "direct_url")
    assert not ok3, "Should reject non-http URL"
    assert "http" in reason3.lower(), f"Reason should mention http: {reason3}"
    
    print("PASS: J25-2_url_validation_enforces_protocol")


def test_access_method_whitelist():
    """J25-3: Access method whitelist is enforced."""
    reg = _make_reg()
    
    # Test all valid methods
    for method in SurfaceAccessMethod:
        ok, reason = reg.validate_access_method("openwebui", method.value)
        assert ok, f"Should allow {method.value}: {reason}"
    
    # Test invalid method
    ok_bad, reason_bad = reg.validate_access_method("openwebui", "iframe")
    assert not ok_bad, "iframe should be rejected per Section 9.4"
    
    ok_unknown, _ = reg.validate_access_method("nonexistent", "direct_url")
    assert not ok_unknown, "Unknown surface should be rejected"
    
    print("PASS: J25-3_access_method_whitelist")


def test_compliance_report_structure():
    """J25-4: Compliance report structure and accuracy."""
    reg = _make_reg()
    report = reg.compliance_report()
    
    assert "total_surfaces" in report
    assert "validated_count" in report
    assert "unvalidated_count" in report
    assert "compliance_pct" in report
    assert "by_category" in report
    assert "surfaces" in report
    
    assert report["total_surfaces"] == 13, f"Expected 13 surfaces: {report['total_surfaces']}"
    assert report["validated_count"] == 0  # None validated by default
    assert report["unvalidated_count"] == 13
    assert report["compliance_pct"] == 0.0
    
    # Check categories exist
    for surface in report["surfaces"].values():
        assert "name" in surface
        assert "access_method" in surface
        assert "category" in surface
        assert "validated" in surface
    
    print("PASS: J25-4_compliance_report_structure")


def test_mark_validated_updates_state():
    """J25-5: mark_validated updates surface state correctly."""
    reg = _make_reg()
    
    ok, _ = reg.mark_validated("openwebui", "Tested and validated locally")
    assert ok, "Should successfully mark surface as validated"
    
    surface = reg.get_surface("openwebui")
    assert surface.validated is True
    
    # Check compliance report updated
    report = reg.compliance_report()
    assert report["validated_count"] == 1
    assert report["compliance_pct"] > 0
    
    print("PASS: J25-5_mark_validated_updates_state")


def test_categories_assigned_per_section():
    """J25-6: Categories are properly assigned per Section 9.4."""
    reg = _make_reg()
    
    dashboard_names = ["hermes_dashboard", "openhands_ui"]
    cli_names = ["kilo_cli", "vibe_cli", "goose_acp"]
    webapp_names = ["openwebui", "comfyui", "forgejo", "grafana", "dgx_dashboard", "jupyterlab"]
    desktop_names = ["hermes_desktop", "vibe_vscode"]
    
    for name in dashboard_names:
        surface = reg.get_surface(name)
        assert surface is not None, f"Surface {name} missing"
        assert surface.category == SurfaceCategory.AGENT_DASHBOARD, \
            f"{name} should be AGENT_DASHBOARD, got {surface.category}"
    
    for name in cli_names:
        surface = reg.get_surface(name)
        assert surface is not None, f"Surface {name} missing"
        assert surface.category == SurfaceCategory.CLI_CONSOLE, \
            f"{name} should be CLI_CONSOLE, got {surface.category}"
    
    for name in webapp_names:
        surface = reg.get_surface(name)
        assert surface is not None, f"Surface {name} missing"
        assert surface.category == SurfaceCategory.WEB_APP, \
            f"{name} should be WEB_APP, got {surface.category}"
    
    for name in desktop_names:
        surface = reg.get_surface(name)
        assert surface is not None, f"Surface {name} missing"
        assert surface.category == SurfaceCategory.DESKTOP, \
            f"{name} should be DESKTOP, got {surface.category}"
    
    print("PASS: J25-6_categories_assigned_per_section")


if __name__ == "__main__":
    test_registry_contains_expected_surfaces()
    test_url_validation_enforces_protocol()
    test_access_method_whitelist()
    test_compliance_report_structure()
    test_mark_validated_updates_state()
    test_categories_assigned_per_section()
    print("\n=== J25_native_surfaces passed ===")
