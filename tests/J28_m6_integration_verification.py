#!/usr/bin/env python3
"""tests/J28_m6_integration_verification.py — M6 Integration Verification (§M6, §G6).

Comprehensive verification that all M6 components work together:
- Profiles, protocols, extensions, surfaces, sub-agents
- Harness adapters integration with contracts
- Vertical contract compliance

Conforms to PLAN.md §M6 (Agents de code) and §G6 (contrat vertical et tests négatifs verts).
"""

import asyncio
import sys
import os

# Ensure src is in path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src'))

from agentic.contracts.agents import (
    get_m6_agent_contracts, 
    get_agent_contract,
    M6AgentContract
)
from agentic.implementations.harness_profiles import get_all_profiles, HarnessProfile
from agentic.implementations.harness_adapters import (
    CodexHarnessAdapter, ClaudeCodeHarnessAdapter, OpenCodeHarnessAdapter,
    KiloCodeHarnessAdapter, VibeHarnessAdapter, PiHarnessAdapter, GooseHarnessAdapter
)


class TestM6Integration:
    """Integration tests for M6 agents."""

    def test_all_m6_agents_have_profiles(self):
        """Verify all M6 agents have harness profiles."""
        profiles = get_all_profiles()
        m6_agents = ["codex", "claude", "opencode", "kilocode", "vibestral", "pi-mono", "goose"]
        
        for agent in m6_agents:
            assert agent in profiles, f"Missing profile for M6 agent: {agent}"
        
        print("PASS: All M6 agents have harness profiles")

    def test_all_m6_agents_have_contracts(self):
        """Verify all M6 agents have vertical contracts."""
        contracts = get_m6_agent_contracts()
        m6_agents = ["codex", "claude", "opencode", "kilocode", "vibestral", "pi", "goose"]
        
        for agent in m6_agents:
            assert agent in contracts, f"Missing contract for M6 agent: {agent}"
        
        print("PASS: All M6 agents have vertical contracts")

    def test_all_m6_agents_have_harness_adapters(self):
        """Verify all M6 agents have harness adapters."""
        adapters = {
            "codex": CodexHarnessAdapter,
            "claude": ClaudeCodeHarnessAdapter,
            "opencode": OpenCodeHarnessAdapter,
            "kilocode": KiloCodeHarnessAdapter,
            "vibestral": VibeHarnessAdapter,
            "pi": PiHarnessAdapter,
            "goose": GooseHarnessAdapter,
        }
        
        for agent, adapter_class in adapters.items():
            assert adapter_class is not None, f"Missing harness adapter for: {agent}"
            adapter = adapter_class()
            assert hasattr(adapter, 'capabilities'), f"Adapter missing capabilities: {agent}"
        
        print("PASS: All M6 agents have harness adapters")

    def test_profile_contract_consistency(self):
        """Verify consistency between profiles and contracts."""
        profiles = get_all_profiles()
        contracts = get_m6_agent_contracts()
        
        # Map contract names to profile names (pi -> pi-mono)
        contract_to_profile = {
            "codex": "codex",
            "claude": "claude", 
            "opencode": "opencode",
            "kilocode": "kilocode",
            "vibestral": "vibestral",
            "pi": "pi-mono",
            "goose": "goose",
        }
        
        for agent, contract_class in contracts.items():
            profile_name = contract_to_profile[agent]
            assert profile_name in profiles, f"Profile {profile_name} not found for contract {agent}"
            
            profile = profiles[profile_name]
            contract = contract_class()
            
            # Check that model protocols are consistent
            contract_protocols = contract.capabilities.model_protocols
            profile_protocol = profile.model_protocol
            
            # Profile protocol should be in contract protocols
            assert profile_protocol in contract_protocols, \
                f"Profile protocol {profile_protocol} not in contract protocols {contract_protocols} for {agent}"
            
            # Check that surfaces are consistent
            contract_surfaces = contract.capabilities.supports_native_surfaces
            profile_surfaces = profile.surfaces
            
            # Contract surfaces should be subset of profile surfaces or vice versa
            for surface in contract_surfaces:
                assert surface in profile_surfaces or any(surface.startswith(ps) for ps in profile_surfaces), \
                    f"Contract surface {surface} not compatible with profile surfaces {profile_surfaces} for {agent}"
            
            # Check repo-e2e support consistency
            assert profile.supports_repo_e2e == contract.capabilities.supports_repo_e2e, \
                f"repo-e2e support mismatch for {agent}"
        
        print("PASS: Profiles and contracts are consistent")

    def test_sub_agents_consistency(self):
        """Verify sub-agents configuration is consistent."""
        profiles = get_all_profiles()
        contracts = get_m6_agent_contracts()
        
        contract_to_profile = {
            "codex": "codex",
            "claude": "claude", 
            "opencode": "opencode",
            "kilocode": "kilocode",
            "vibestral": "vibestral",
            "pi": "pi-mono",
            "goose": "goose",
        }
        
        for agent, contract_class in contracts.items():
            profile_name = contract_to_profile[agent]
            profile = profiles[profile_name]
            contract = contract_class()
            
            contract_supports_sub_agents = contract.capabilities.supports_sub_agents
            profile_sub_agents_mode = profile.sub_agents.get("mode", "none")
            
            # If contract supports sub-agents, profile should not be "none"
            if contract_supports_sub_agents:
                assert profile_sub_agents_mode != "none", \
                    f"Contract supports sub-agents but profile mode is 'none' for {agent}"
            else:
                # If contract doesn't support sub-agents, profile should be "none"
                assert profile_sub_agents_mode == "none", \
                    f"Contract doesn't support sub-agents but profile mode is '{profile_sub_agents_mode}' for {agent}"
        
        print("PASS: Sub-agents configuration is consistent")

    def test_profiles_have_all_required_fields(self):
        """Verify all M6 profiles have required fields for M6."""
        profiles = get_all_profiles()
        m6_agents = ["codex", "claude", "opencode", "kilocode", "vibestral", "pi-mono", "goose"]
        
        required_fields = ['harness_name', 'model_protocol', 'architecture', 'persistent_files', 
                         'surfaces', 'permissions', 'sub_agents', 'tests', 'supports_repo_e2e']
        
        for agent in m6_agents:
            profile = profiles[agent]
            for field in required_fields:
                assert hasattr(profile, field), f"Profile {agent} missing field: {field}"
                assert getattr(profile, field) is not None, f"Profile {agent} field {field} is None"
        
        print("PASS: All M6 profiles have required fields")

    def test_contracts_have_all_required_methods(self):
        """Verify all M6 contracts have required methods and properties."""
        contracts = get_m6_agent_contracts()
        required_properties = ['agent_name', 'capabilities']
        required_methods = ['validate_model_protocol', 
                          'validate_extensions', 'validate_github_integration',
                          'validate_huggingface_integration', 'validate_repo_e2e_compatibility',
                          'get_native_surfaces']
        
        for agent, contract_class in contracts.items():
            contract = contract_class()
            
            # Check properties
            for prop in required_properties:
                assert hasattr(contract, prop), f"Contract {agent} missing property: {prop}"
            
            # Check methods
            for method in required_methods:
                assert hasattr(contract, method), f"Contract {agent} missing method: {method}"
                assert callable(getattr(contract, method)), f"Contract {agent} method {method} not callable"
        
        print("PASS: All M6 contracts have required properties and methods")


class TestM6ProtocolConsistency:
    """Test protocol consistency across M6 components."""

    def test_model_protocols_consistency(self):
        """Verify model protocols are consistently defined across contracts and profiles."""
        profiles = get_all_profiles()
        contracts = get_m6_agent_contracts()
        
        contract_to_profile = {
            "codex": "codex",
            "claude": "claude", 
            "opencode": "opencode",
            "kilocode": "kilocode",
            "vibestral": "vibestral",
            "pi": "pi-mono",
            "goose": "goose",
        }
        
        for agent, contract_class in contracts.items():
            profile_name = contract_to_profile[agent]
            profile = profiles[profile_name]
            contract = contract_class()
            
            profile_protocol = profile.model_protocol
            contract_protocols = contract.capabilities.model_protocols
            
            # Profile protocol should be supported by contract
            assert profile_protocol in contract_protocols, \
                f"Profile protocol '{profile_protocol}' not supported by contract for {agent}"
        
        print("PASS: Model protocols are consistent")

    def test_protocol_validation_works(self):
        """Test that protocol validation works for all agents."""
        contracts = get_m6_agent_contracts()
        
        for agent, contract_class in contracts.items():
            contract = contract_class()
            
            # Get the first protocol from capabilities (should be supported)
            protocols = contract.capabilities.model_protocols
            if protocols:
                first_protocol = protocols[0]
                assert asyncio.run(contract.validate_model_protocol(first_protocol)) is True, \
                    f"Contract {agent} doesn't support its own first protocol: {first_protocol}"
        
        print("PASS: Protocol validation works for all agents")


class TestM6Surfaces:
    """Test surface consistency across M6 components."""

    def test_surfaces_consistency(self):
        """Verify surfaces are consistently defined."""
        profiles = get_all_profiles()
        contracts = get_m6_agent_contracts()
        
        contract_to_profile = {
            "codex": "codex",
            "claude": "claude", 
            "opencode": "opencode",
            "kilocode": "kilocode",
            "vibestral": "vibestral",
            "pi": "pi-mono",
            "goose": "goose",
        }
        
        for agent, contract_class in contracts.items():
            profile_name = contract_to_profile[agent]
            profile = profiles[profile_name]
            contract = contract_class()
            
            contract_surfaces = set(contract.capabilities.supports_native_surfaces)
            profile_surfaces = set(profile.surfaces)
            
            # Contract surfaces should be subset of profile surfaces or have reasonable overlap
            # Some mapping might be needed (e.g., "web_console" vs "web")
            overlapping = contract_surfaces.intersection(profile_surfaces)
            assert len(overlapping) > 0, \
                f"No surface overlap between contract {contract_surfaces} and profile {profile_surfaces} for {agent}"
        
        print("PASS: Surfaces are consistent")


class TestM6Extensions:
    """Test extension support across M6 components."""

    def test_extensions_validation_works(self):
        """Test that extension validation works for all agents."""
        contracts = get_m6_agent_contracts()
        
        for agent, contract_class in contracts.items():
            contract = contract_class()
            
            # Test empty list (should always work)
            errors = asyncio.run(contract.validate_extensions([]))
            assert len(errors) == 0, f"Contract {agent} rejects empty extensions list"
            
            # Test with valid extension (should work)
            if contract.capabilities.supports_extensions:
                errors = asyncio.run(contract.validate_extensions(["valid_extension"]))
                # Should either accept or have specific validation
                assert len(errors) == 0 or any("valid_extension" in err for err in errors), \
                    f"Contract {agent} extension validation unexpected: {errors}"
        
        print("PASS: Extension validation works for all agents")

    def test_extensions_support_consistency(self):
        """Verify extension support is consistent between contracts and capabilities."""
        contracts = get_m6_agent_contracts()
        
        for agent, contract_class in contracts.items():
            contract = contract_class()
            caps = contract.capabilities
            
            # If supports_extensions is False, validation should reject all non-empty lists
            if not caps.supports_extensions:
                errors = asyncio.run(contract.validate_extensions(["any_extension"]))
                assert len(errors) > 0, f"Contract {agent} doesn't support extensions but accepts them"
        
        print("PASS: Extension support is consistent")


# =============================================================================
# Test Runner
# =============================================================================

def run_all_tests():
    """Run all M6 integration verification tests."""
    
    # Non-async tests
    test_class = TestM6Integration()
    test_class.test_all_m6_agents_have_profiles()
    test_class.test_all_m6_agents_have_contracts()
    test_class.test_all_m6_agents_have_harness_adapters()
    test_class.test_profile_contract_consistency()
    test_class.test_sub_agents_consistency()
    test_class.test_profiles_have_all_required_fields()
    test_class.test_contracts_have_all_required_methods()
    
    # Protocol tests
    proto_test = TestM6ProtocolConsistency()
    proto_test.test_model_protocols_consistency()
    proto_test.test_protocol_validation_works()
    
    # Surface tests
    surface_test = TestM6Surfaces()
    surface_test.test_surfaces_consistency()
    
    # Extension tests
    ext_test = TestM6Extensions()
    ext_test.test_extensions_validation_works()
    ext_test.test_extensions_support_consistency()


if __name__ == "__main__":
    print("Running M6 Integration Verification Tests...")
    print("=" * 50)
    
    try:
        run_all_tests()
        print("=" * 50)
        print("All M6 integration verification tests PASSED!")
        print(f"J28_m6_integration_verification.py: PASS")
        sys.exit(0)
    except Exception as e:
        print(f"Test FAILED: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)