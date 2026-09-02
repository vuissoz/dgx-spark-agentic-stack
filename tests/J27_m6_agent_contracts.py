#!/usr/bin/env python3
"""tests/J27_m6_agent_contracts.py — M6 Agent Contract Tests (§M6, §G6).

Comprehensive negative tests for all M6 code agents.
Each test validates a specific aspect of the agent contracts to ensure
vertical contracts and negative scenarios are properly handled.

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
    CodexContract, ClaudeContract, OpenCodeContract,
    KiloCodeContract, VibeContract, PiContract, GooseContract,
    M6AgentContract, AgentCapabilities
)


class TestM6AgentContracts:
    """Test suite for M6 agent vertical contracts."""

    def test_all_agent_contracts_exist(self):
        """Test that all M6 agent contracts are available."""
        contracts = get_m6_agent_contracts()
        expected_agents = ["codex", "claude", "opencode", "kilocode", "vibestral", "pi", "goose"]
        
        assert len(contracts) == 7, f"Expected 7 agents, got {len(contracts)}"
        
        for agent in expected_agents:
            assert agent in contracts, f"Missing contract for agent: {agent}"
        
        print("PASS: All M6 agent contracts exist")

    def test_get_agent_contract(self):
        """Test that get_agent_contract returns correct contract instances."""
        for agent_name in ["codex", "claude", "opencode", "kilocode", "vibestral", "pi", "goose"]:
            contract = get_agent_contract(agent_name)
            assert contract is not None, f"No contract found for {agent_name}"
            assert isinstance(contract, M6AgentContract), f"Invalid contract type for {agent_name}"
            assert contract.agent_name == agent_name, f"Wrong agent name for {agent_name}"
        
        # Test non-existent agent
        assert get_agent_contract("nonexistent") is None
        
        print("PASS: get_agent_contract works correctly")

    def test_agent_names_unique(self):
        """Test that all agent names are unique."""
        contracts = get_m6_agent_contracts()
        names = []
        for agent_name, contract_class in contracts.items():
            contract = contract_class()
            names.append(contract.agent_name)
        
        assert len(names) == len(set(names)), "Agent names are not unique"
        
        print("PASS: All agent names are unique")


class TestCodexContract:
    """Negative tests for Codex agent contract."""

    async def test_codex_capabilities(self):
        """Test Codex capabilities are correctly defined."""
        contract = CodexContract()
        caps = contract.capabilities
        
        # Positive assertions
        assert caps.tool_call_mode == "streaming"
        assert caps.supports_streaming is True
        assert caps.supports_model_routing is True
        assert caps.supports_repo_e2e is True
        assert "cli" in caps.supports_native_surfaces
        assert "openai_responses" in caps.model_protocols
        
        # Negative assertions (should NOT have these capabilities)
        assert caps.supports_sub_agents is False
        assert caps.requires_gpu is False
        assert caps.supports_huggingface_integration is False
        
        print("PASS: Codex capabilities are correct")

    async def test_codex_protocol_validation(self):
        """Test Codex protocol validation (negative scenarios)."""
        contract = CodexContract()
        
        # Positive cases
        assert await contract.validate_model_protocol("openai_responses") is True
        assert await contract.validate_model_protocol("openai_chat_completions") is True
        
        # Negative cases - should reject unsupported protocols
        assert await contract.validate_model_protocol("anthropic_messages") is False
        assert await contract.validate_model_protocol("ollama_native") is False
        assert await contract.validate_model_protocol("invalid_protocol") is False
        
        print("PASS: Codex protocol validation works")

    async def test_codex_extension_validation(self):
        """Test Codex extension validation (negative scenarios)."""
        contract = CodexContract()
        
        # Positive cases - allowed extensions
        assert len(await contract.validate_extensions(["codex_github"])) == 0
        assert len(await contract.validate_extensions(["codex_fs"])) == 0
        
        # Negative cases - docker extensions should be rejected
        errors = await contract.validate_extensions(["docker_build"])
        assert len(errors) == 1
        assert "docker_" in errors[0]
        
        # Mixed cases
        errors = await contract.validate_extensions(["codex_github", "docker_run"])
        assert len(errors) == 1
        assert "docker_run" in errors[0]
        
        print("PASS: Codex extension validation works")

    async def test_codex_integration_validation(self):
        """Test Codex integration validation (negative scenarios)."""
        contract = CodexContract()
        
        # Positive cases
        assert await contract.validate_github_integration({"enabled": True, "token": "gh_token"}) is True
        
        # Negative cases - missing required fields
        assert await contract.validate_github_integration({"enabled": True}) is False
        assert await contract.validate_github_integration({"token": "gh_token"}) is False
        assert await contract.validate_github_integration({}) is False
        assert await contract.validate_github_integration({"enabled": False, "token": "gh_token"}) is False
        
        # HuggingFace should not be supported
        assert await contract.validate_huggingface_integration({"enabled": True, "token": "hf_token"}) is False
        
        print("PASS: Codex integration validation works")

    async def test_codex_repo_e2e_compatibility(self):
        """Test Codex repo-e2e compatibility."""
        contract = CodexContract()
        assert await contract.validate_repo_e2e_compatibility() is True
        
        print("PASS: Codex repo-e2e compatibility works")

    async def test_codex_surfaces(self):
        """Test Codex native surfaces."""
        contract = CodexContract()
        surfaces = await contract.get_native_surfaces()
        
        expected_surfaces = ["cli", "ide", "web"]
        assert set(surfaces) == set(expected_surfaces), f"Expected {expected_surfaces}, got {surfaces}"
        
        print("PASS: Codex surfaces are correct")


class TestClaudeContract:
    """Negative tests for Claude agent contract."""

    async def test_claude_capabilities(self):
        """Test Claude capabilities are correctly defined."""
        contract = ClaudeContract()
        caps = contract.capabilities
        
        # Positive assertions
        assert caps.tool_call_mode == "streaming"
        assert caps.supports_sub_agents is True
        assert caps.max_depth == 3
        assert caps.supports_streaming is True
        assert caps.supports_github_integration is True
        assert caps.supports_huggingface_integration is True
        assert "anthropic_messages" in caps.model_protocols
        
        # Negative assertions
        assert caps.requires_gpu is False
        
        print("PASS: Claude capabilities are correct")

    async def test_claude_protocol_validation(self):
        """Test Claude protocol validation (negative scenarios)."""
        contract = ClaudeContract()
        
        # Positive cases
        assert await contract.validate_model_protocol("anthropic_messages") is True
        assert await contract.validate_model_protocol("openai_chat_completions") is True
        
        # Negative cases
        assert await contract.validate_model_protocol("openai_responses") is False
        assert await contract.validate_model_protocol("ollama_native") is False
        
        print("PASS: Claude protocol validation works")

    async def test_claude_extension_validation(self):
        """Test Claude extension validation (negative scenarios)."""
        contract = ClaudeContract()
        
        # Positive cases
        assert len(await contract.validate_extensions(["mcp_approved_github"])) == 0
        
        # Negative cases - unapproved MCP extensions
        errors = await contract.validate_extensions(["mcp_filesystem"])
        assert len(errors) == 1
        assert "allowlist" in errors[0]
        
        print("PASS: Claude extension validation works")

    async def test_claude_integration_validation(self):
        """Test Claude integration validation."""
        contract = ClaudeContract()
        
        # Both GitHub and HuggingFace should be supported
        assert await contract.validate_github_integration({"enabled": True, "token": "gh_token"}) is True
        assert await contract.validate_huggingface_integration({"enabled": True, "token": "hf_token"}) is True
        
        # Negative cases
        assert await contract.validate_github_integration({"enabled": True}) is False
        assert await contract.validate_huggingface_integration({"token": "hf_token"}) is False
        
        print("PASS: Claude integration validation works")


class TestOpenCodeContract:
    """Negative tests for OpenCode agent contract."""

    async def test_opencode_capabilities(self):
        """Test OpenCode capabilities are correctly defined."""
        contract = OpenCodeContract()
        caps = contract.capabilities
        
        assert caps.tool_call_mode == "streaming"
        assert caps.supports_sub_agents is False
        assert caps.supports_model_routing is True
        assert caps.supports_extensions is True
        assert caps.supports_github_integration is True
        assert caps.supports_huggingface_integration is True
        assert "chat_completions" in caps.model_protocols
        
        print("PASS: OpenCode capabilities are correct")

    async def test_opencode_extension_validation(self):
        """Test OpenCode extension validation (negative scenarios)."""
        contract = OpenCodeContract()
        
        # Positive cases
        assert len(await contract.validate_extensions(["safe_extension"])) == 0
        
        # Negative cases - unsafe extensions (must end with _unsafe)
        errors = await contract.validate_extensions(["my_unsafe"])
        assert len(errors) == 1
        assert "Unsafe extension" in errors[0]
        
        print("PASS: OpenCode extension validation works")


class TestKiloCodeContract:
    """Negative tests for KiloCode agent contract."""

    async def test_kilocode_capabilities(self):
        """Test KiloCode capabilities are correctly defined."""
        contract = KiloCodeContract()
        caps = contract.capabilities
        
        assert caps.tool_call_mode == "streaming"
        assert caps.supports_sub_agents is True
        assert caps.max_depth == 2
        assert caps.supports_model_routing is True
        assert caps.supports_extensions is False  # KiloCode doesn't support extensions
        assert caps.supports_github_integration is True
        assert caps.supports_huggingface_integration is False
        assert "ollama_native" in caps.model_protocols
        
        print("PASS: KiloCode capabilities are correct")

    async def test_kilocode_extension_validation(self):
        """Test KiloCode extension validation (negative scenarios)."""
        contract = KiloCodeContract()
        
        # KiloCode doesn't support extensions - any extension should cause error
        errors = await contract.validate_extensions(["any_extension"])
        assert len(errors) == 1
        assert "does not support extensions" in errors[0]
        
        # Empty list should be fine
        errors = await contract.validate_extensions([])
        assert len(errors) == 0
        
        print("PASS: KiloCode extension validation works")

    async def test_kilocode_protocol_validation(self):
        """Test KiloCode protocol validation."""
        contract = KiloCodeContract()
        
        # Positive cases
        assert await contract.validate_model_protocol("ollama_native") is True
        assert await contract.validate_model_protocol("openai_chat_completions") is True
        
        # Negative cases
        assert await contract.validate_model_protocol("anthropic_messages") is False
        
        print("PASS: KiloCode protocol validation works")


class TestVibeContract:
    """Negative tests for Vibe agent contract."""

    async def test_vibe_capabilities(self):
        """Test Vibe capabilities are correctly defined."""
        contract = VibeContract()
        caps = contract.capabilities
        
        assert caps.tool_call_mode == "streaming"
        assert caps.supports_sub_agents is False
        assert caps.supports_model_routing is True
        assert caps.supports_extensions is True
        assert caps.supports_github_integration is True
        assert caps.supports_huggingface_integration is True
        assert "configurable_endpoint" in caps.model_protocols
        assert "vscode" in caps.supports_native_surfaces
        assert "acp" in caps.supports_native_surfaces
        
        print("PASS: Vibe capabilities are correct")

    async def test_vibe_extension_validation(self):
        """Test Vibe extension validation (negative scenarios)."""
        contract = VibeContract()
        
        # Positive cases - built-in extensions
        assert len(await contract.validate_extensions(["vibe_code"])) == 0
        
        # Negative cases - custom extensions need review
        errors = await contract.validate_extensions(["custom_unsafe"])
        assert len(errors) == 1
        assert "requires review" in errors[0]
        
        print("PASS: Vibe extension validation works")

    async def test_vibe_protocol_validation(self):
        """Test Vibe protocol validation."""
        contract = VibeContract()
        
        # Vibe supports multiple protocols
        assert await contract.validate_model_protocol("configurable_endpoint") is True
        assert await contract.validate_model_protocol("openai_chat_completions") is True
        assert await contract.validate_model_protocol("anthropic_messages") is True
        
        # Negative case
        assert await contract.validate_model_protocol("ollama_native") is False
        
        print("PASS: Vibe protocol validation works")


class TestPiContract:
    """Negative tests for Pi agent contract."""

    async def test_pi_capabilities(self):
        """Test Pi capabilities are correctly defined."""
        contract = PiContract()
        caps = contract.capabilities
        
        assert caps.tool_call_mode == "streaming"
        assert caps.supports_sub_agents is False
        assert caps.supports_model_routing is True
        assert caps.supports_extensions is True
        assert caps.supports_github_integration is True
        assert caps.supports_huggingface_integration is False
        assert "desktop" in caps.supports_native_surfaces
        assert "configurable" in caps.model_protocols
        
        print("PASS: Pi capabilities are correct")

    async def test_pi_extension_validation(self):
        """Test Pi extension validation (negative scenarios)."""
        contract = PiContract()
        
        # Positive cases - built-in extensions
        assert len(await contract.validate_extensions(["pi_github"])) == 0
        
        # Negative cases - extension name too long
        long_name = "a" * 51
        errors = await contract.validate_extensions([long_name])
        assert len(errors) == 1
        assert "too long" in errors[0]
        
        print("PASS: Pi extension validation works")

    async def test_pi_protocol_validation(self):
        """Test Pi protocol validation."""
        contract = PiContract()
        
        # Multiple protocols supported
        assert await contract.validate_model_protocol("configurable") is True
        assert await contract.validate_model_protocol("openai_chat_completions") is True
        assert await contract.validate_model_protocol("anthropic_messages") is True
        
        # Negative case
        assert await contract.validate_model_protocol("ollama_native") is False
        
        print("PASS: Pi protocol validation works")


class TestGooseContract:
    """Negative tests for Goose agent contract."""

    async def test_goose_capabilities(self):
        """Test Goose capabilities are correctly defined."""
        contract = GooseContract()
        caps = contract.capabilities
        
        assert caps.tool_call_mode == "streaming"
        assert caps.supports_sub_agents is True
        assert caps.max_depth == 2
        assert caps.supports_model_routing is True
        assert caps.supports_extensions is True
        assert caps.supports_github_integration is True
        assert caps.supports_huggingface_integration is True
        assert "acp" in caps.supports_native_surfaces
        assert "chat_completions" in caps.model_protocols
        
        print("PASS: Goose capabilities are correct")

    async def test_goose_extension_validation(self):
        """Test Goose extension validation (negative scenarios)."""
        contract = GooseContract()
        
        # Positive cases - recipe and provider extensions
        assert len(await contract.validate_extensions(["recipe_dev"])) == 0
        assert len(await contract.validate_extensions(["provider_ollama"])) == 0
        
        # Other extensions should not cause errors (Goose is permissive)
        assert len(await contract.validate_extensions(["custom_ext"])) == 0
        
        print("PASS: Goose extension validation works")

    async def test_goose_protocol_validation(self):
        """Test Goose protocol validation."""
        contract = GooseContract()
        
        assert await contract.validate_model_protocol("chat_completions") is True
        assert await contract.validate_model_protocol("openai_chat_completions") is True
        
        # Negative case
        assert await contract.validate_model_protocol("anthropic_messages") is False
        
        print("PASS: Goose protocol validation works")


class TestAgentCapabilitiesDataClass:
    """Test the AgentCapabilities dataclass."""

    def test_agent_capabilities_defaults(self):
        """Test AgentCapabilities default values."""
        caps = AgentCapabilities()
        
        assert caps.tool_call_mode == "streaming"
        assert caps.supports_sub_agents is False
        assert caps.max_depth == 1
        assert caps.supports_streaming is True
        assert caps.requires_gpu is False
        assert caps.supports_model_routing is False
        assert caps.supports_extensions is False
        assert caps.supports_github_integration is False
        assert caps.supports_huggingface_integration is False
        assert caps.supports_repo_e2e is False
        assert caps.supports_native_surfaces == []
        assert caps.model_protocols == []
        
        print("PASS: AgentCapabilities defaults are correct")

    def test_agent_capabilities_custom_values(self):
        """Test AgentCapabilities with custom values."""
        caps = AgentCapabilities(
            tool_call_mode="batch",
            supports_sub_agents=True,
            max_depth=5,
            supports_streaming=False,
            supports_model_routing=True,
            supports_native_surfaces=["cli", "web"],
            model_protocols=["custom_protocol"]
        )
        
        assert caps.tool_call_mode == "batch"
        assert caps.supports_sub_agents is True
        assert caps.max_depth == 5
        assert caps.supports_streaming is False
        assert caps.supports_model_routing is True
        assert "cli" in caps.supports_native_surfaces
        assert "custom_protocol" in caps.model_protocols
        
        print("PASS: AgentCapabilities custom values work")


# =============================================================================
# Test Runner
# =============================================================================

async def run_all_tests():
    """Run all M6 agent contract tests."""
    test_class = TestM6AgentContracts()
    
    # Run base contract tests
    test_class.test_all_agent_contracts_exist()
    test_class.test_get_agent_contract()
    test_class.test_agent_names_unique()
    
    # Run capability tests
    test_class = TestAgentCapabilitiesDataClass()
    test_class.test_agent_capabilities_defaults()
    test_class.test_agent_capabilities_custom_values()
    
    # Run individual agent tests
    codex_test = TestCodexContract()
    await codex_test.test_codex_capabilities()
    await codex_test.test_codex_protocol_validation()
    await codex_test.test_codex_extension_validation()
    await codex_test.test_codex_integration_validation()
    await codex_test.test_codex_repo_e2e_compatibility()
    await codex_test.test_codex_surfaces()
    
    claude_test = TestClaudeContract()
    await claude_test.test_claude_capabilities()
    await claude_test.test_claude_protocol_validation()
    await claude_test.test_claude_extension_validation()
    await claude_test.test_claude_integration_validation()
    
    opencode_test = TestOpenCodeContract()
    await opencode_test.test_opencode_capabilities()
    await opencode_test.test_opencode_extension_validation()
    
    kilocode_test = TestKiloCodeContract()
    await kilocode_test.test_kilocode_capabilities()
    await kilocode_test.test_kilocode_extension_validation()
    await kilocode_test.test_kilocode_protocol_validation()
    
    vibe_test = TestVibeContract()
    await vibe_test.test_vibe_capabilities()
    await vibe_test.test_vibe_extension_validation()
    await vibe_test.test_vibe_protocol_validation()
    
    pi_test = TestPiContract()
    await pi_test.test_pi_capabilities()
    await pi_test.test_pi_extension_validation()
    await pi_test.test_pi_protocol_validation()
    
    goose_test = TestGooseContract()
    await goose_test.test_goose_capabilities()
    await goose_test.test_goose_extension_validation()
    await goose_test.test_goose_protocol_validation()


if __name__ == "__main__":
    print("Running M6 Agent Contract Tests...")
    print("=" * 50)
    
    try:
        asyncio.run(run_all_tests())
        print("=" * 50)
        print("All M6 agent contract tests PASSED!")
        print(f"J27_m6_agent_contracts.py: PASS")
        sys.exit(0)
    except Exception as e:
        print(f"Test FAILED: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)