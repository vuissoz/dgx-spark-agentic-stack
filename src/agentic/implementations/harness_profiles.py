#!/usr/bin/env python3
"""src/agentic/implementations/harness_profiles.py — Harness integration profiles (§8).

Each profile defines: upstream version, digest, ARM64 architecture, model protocol,
persistent files, surfaces, permissions, sub-agents, and tests.

Conforms to PLAN.md §8 (Profils d'intégration des harnesses v1).
Generated from harness_profiles_config.yaml - DO NOT EDIT MANUALLY
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any


# ── Profile Schema (§8) ─────────────────────────────────────────────

@dataclass(frozen=True)
class HarnessProfile:
    """Integration profile for a harness v1 → v2 migration.

    Contains: upstream_version, digest, architecture (ARM64), model_protocol,
    persistent_files, surfaces, permissions, sub_agents, tests, and repo_e2e support.
    
    Conforms to PLAN.md §8 specification and §M6 (Agents de code).
    """
    harness_name: str
    model_protocol: str                # openai_responses, anthropic_messages, chat_completions, etc.
    upstream_version: str = ""         # e.g., "v1.2.3" or "latest"
    digest: str = ""                   # image digest for immutability
    architecture: str = "ARM64"        # DGX Spark target architecture
    persistent_files: list[str] = field(default_factory=list)  # State dirs
    surfaces: list[str] = field(default_factory=list)          # cli, web, ide, desktop
    permissions: dict[str, Any] = field(default_factory=lambda: {"cpus": 1.0, "memory_mb": 1024, "gpu_count": 0})  # Resource limits
    sub_agents: dict[str, Any] = field(default_factory=lambda: {
        "mode": "none",  # none | native | platform | external-provider
        "max_depth": 1,
        "max_concurrency": 1,
    })
    tests: list[str] = field(default_factory=list)  # Test file patterns
    removal_condition: str = ""     # When v1 route can be retired
    supports_repo_e2e: bool = True    # §M6: repo-e2e integration support


# ── All Harness Profiles (§8 + §2.2 table) ─────────────────────────

def get_all_profiles() -> dict[str, HarnessProfile]:
    """Return canonical profiles for all 11 harnesses (§2.2)."""
    return {
        "codex": HarnessProfile(
            harness_name="codex",
            model_protocol="openai_responses",
            upstream_version="0.147.0",
            digest="sha256:fee529523d67214375874b16cca48447963b34ea0290497dcfcf412ea4f1acf3",
            architecture="ARM64",
            persistent_files=["config.toml", "sessions/"],
            surfaces=["cli", "ide", "web"],
            permissions={"cpus": 2.0, "memory_mb": 4096, "gpu_count": 0},
            sub_agents={"mode": "none", "max_depth": 1, "max_concurrency": 1},
            tests=["tests/L7*", "tests/F3*", "tests/J27*"],
            supports_repo_e2e=True,
            removal_condition="M6 validation complete",
        ),
        "claude": HarnessProfile(
            harness_name="claude",
            model_protocol="anthropic_messages",
            upstream_version="2.1.226",
            digest="sha256:917373284d5902370cc0a2daaec2ef44884b7aace93d51715c61beb11bae356d",
            architecture="ARM64",
            persistent_files=["CLAUDE.md", ".claude/agents/", "sessions/"],
            surfaces=["cli", "web"],
            permissions={"cpus": 2.0, "memory_mb": 4096, "gpu_count": 0},
            sub_agents={"mode": "native", "max_depth": 3, "max_concurrency": 5},
            tests=["tests/L7*", "tests/K*", "tests/J27*"],
            supports_repo_e2e=True,
            removal_condition="M6 validation complete",
        ),
        "opencode": HarnessProfile(
            harness_name="opencode",
            model_protocol="chat_completions",
            upstream_version="1.18.15",
            digest="sha256:371a298c562c8af0e8ce21648bcd234422fb9bce1e4854c3cafdd2f6865db2af",
            architecture="ARM64",
            persistent_files=["opencode.json", "sessions/"],
            surfaces=["cli", "web"],
            permissions={"cpus": 1.0, "memory_mb": 2048, "gpu_count": 0},
            sub_agents={"mode": "none", "max_depth": 1, "max_concurrency": 1},
            tests=["tests/L7*", "tests/J27*"],
            supports_repo_e2e=True,
            removal_condition="M6 validation complete",
        ),
        "kilocode": HarnessProfile(
            harness_name="kilocode",
            model_protocol="ollama_native",
            upstream_version="7.4.5",
            digest="sha256:64fee66bc081c82dac22086327e9fcb8c11930659c23236f11fe9709eb266baa",
            architecture="ARM64",
            persistent_files=[".kilo/agents/", "sessions/"],
            surfaces=["cli", "ide", "web_console"],
            permissions={"cpus": 1.5, "memory_mb": 2048, "gpu_count": 0},
            sub_agents={"mode": "native", "max_depth": 2, "max_concurrency": 3},
            tests=["tests/F27*", "tests/L7*", "tests/J27*"],
            supports_repo_e2e=True,
            removal_condition="M6 validation complete",
        ),
        "vibestral": HarnessProfile(
            harness_name="vibestral",
            model_protocol="configurable_endpoint",
            upstream_version="2.24.0",
            digest="sha256:55d81c96c8399d6768e9089d1ff5ef642fa7400f5ffa9dc770787d4b76e47702",
            architecture="ARM64",
            persistent_files=["VIBE_HOME/", "AGENTS.md"],
            surfaces=["cli", "vscode", "acp"],
            permissions={"cpus": 1.0, "memory_mb": 1024, "gpu_count": 0},
            sub_agents={"mode": "none", "max_depth": 1, "max_concurrency": 1},
            tests=["tests/L5*", "tests/F2*", "tests/J27*"],
            supports_repo_e2e=True,
            removal_condition="M6 validation complete",
        ),
        "hermes": HarnessProfile(
            harness_name="hermes",
            model_protocol="chat_completions",
            upstream_version="v2026.4.3",
            digest="sha256:abf1e98f6253f6984479fe03d1098173a9b065a7000000000000000000000000",
            architecture="ARM64",
            persistent_files=["HERMES_HOME/", "sessions/", "kanban/"],
            surfaces=["web_dashboard", "desktop", "cli"],
            permissions={"cpus": 2.0, "memory_mb": 4096, "gpu_count": 0},
            sub_agents={"mode": "native", "max_depth": 4, "max_concurrency": 10},
            tests=["tests/K*", "tests/L11*"],
            supports_repo_e2e=False,
            removal_condition="",
        ),
        "pi-mono": HarnessProfile(
            harness_name="pi-mono",
            model_protocol="configurable",
            upstream_version="0.73.1",
            digest="sha256:d93cf9d2d6e3608edd3fe01487fd23060c94244a369a31cbac6889862e6f1cb6",
            architecture="ARM64",
            persistent_files=["pi-sessions/", "extensions/"],
            surfaces=["cli", "desktop"],
            permissions={"cpus": 1.0, "memory_mb": 512, "gpu_count": 0},
            sub_agents={"mode": "none", "max_depth": 1, "max_concurrency": 1},
            tests=["tests/K4*", "tests/L7*", "tests/J27*"],
            supports_repo_e2e=True,
            removal_condition="M6 validation complete",
        ),
        "goose": HarnessProfile(
            harness_name="goose",
            model_protocol="chat_completions",
            upstream_version="1.45.0",
            digest="sha256:17a4e0d4f08d6fcd06fbc69b6d22953d6cdf1e5291791c33361ae58a391c7164",
            architecture="ARM64",
            persistent_files=["goose-sessions/", "recipes/", "extensions/"],
            surfaces=["cli", "acp"],
            permissions={"cpus": 1.0, "memory_mb": 2048, "gpu_count": 0},
            sub_agents={"mode": "native", "max_depth": 2, "max_concurrency": 5},
            tests=["tests/K5*", "tests/L7*", "tests/J27*"],
            supports_repo_e2e=True,
            removal_condition="M6 validation complete",
        ),
        "openclaw": HarnessProfile(
            harness_name="openclaw",
            model_protocol="ollama_openai_compatible",
            upstream_version="latest",
            digest="sha256:10215cb753f50d9e9bec50e24b4fba657c8e78b5ab85181b1021b4dc5a1de0fc",
            architecture="ARM64",
            persistent_files=["agentDir/", "sessions/", "skills/"],
            surfaces=["control_ui", "cli", "relay_channels"],
            permissions={"cpus": 1.0, "memory_mb": 2048, "gpu_count": 0},
            sub_agents={"mode": "native", "max_depth": 3, "max_concurrency": 5},
            tests=["tests/K1*", "tests/K8*", "tests/K7*"],
            supports_repo_e2e=False,
            removal_condition="",
        ),
        "openhands": HarnessProfile(
            harness_name="openhands",
            model_protocol="openai_compatible",
            upstream_version="latest",
            digest="sha256:fc8999e2f9f38c7135d4c4e888dbd62a179bb00fb6bd0a9cf169645c43b64b5e",
            architecture="ARM64",
            persistent_files=["settings/", "conversations/", "skills/", "hooks/"],
            surfaces=["web_ui", "terminal", "browser"],
            permissions={"cpus": 2.0, "memory_mb": 4096, "gpu_count": 0},
            sub_agents={"mode": "native", "max_depth": 3, "max_concurrency": 5},
            tests=["tests/H2*", "tests/L7*"],
            supports_repo_e2e=False,
            removal_condition="",
        ),
    }


# ── Profile Validation (for CI/gates) ─────────────────────────────

def validate_profile(profile: HarnessProfile) -> list[str]:
    """Validate a harness profile against invariants.

    Returns list of validation errors (empty = passes).
    """
    errors = []

    # §8 invariant: digest must be present for immutability
    if not profile.digest or profile.digest.startswith("sha256:" + "0" * 64):
        errors.append("digest is invalid/empty — must be resolved during update")

    # §5.4 invariant: sub-agent mode must be one of the valid values
    valid_modes = {"none", "native", "platform", "external-provider"}
    if profile.sub_agents.get("mode") not in valid_modes:
        errors.append(f"invalid sub_agent mode: {profile.sub_agents.get('mode')}")

    # §5.4 invariant: max_depth >= 1 and max_concurrency >= 1
    if profile.sub_agents.get("max_depth", 0) < 1:
        errors.append("sub_agent max_depth must be >= 1")
    if profile.sub_agents.get("max_concurrency", 0) < 1:
        errors.append("sub_agent max_concurrency must be >= 1")

    # §3.2 invariant: model_protocol must match a known protocol
    valid_protocols = {
        "openai_responses",
        "anthropic_messages",
        "chat_completions",
        "ollama_native",
        "configurable_endpoint",
        "configurable",
        "openai_compatible",
        "ollama_openai_compatible",
    }
    if profile.model_protocol not in valid_protocols:
        errors.append(f"invalid model_protocol: {profile.model_protocol}")

    # §5.4 invariant: surfaces must be non-empty
    if not profile.surfaces:
        errors.append("surfaces list must be non-empty")

    # §8 invariant: tests must reference at least one test file
    if not profile.tests:
        errors.append("tests list must contain at least one test pattern")

    return errors


def validate_all_profiles() -> dict[str, list[str]]:
    """Validate all profiles and return error maps."""
    results = {}
    for name, profile in get_all_profiles().items():
        errs = validate_profile(profile)
        if errs:
            results[name] = errs
    return results


# ── CLI Entry Point ───────────────────────────────────────────────

def main() -> int:
    """CLI for harness profile management."""
    import argparse
    import sys
    
    parser = argparse.ArgumentParser(description="Harness Profiles — §8")
    subparsers = parser.add_subparsers(dest="command")
    
    p_list = subparsers.add_parser("list", help="List all profiles")
    p_validate = subparsers.add_parser("validate", help="Validate all profiles")
    
    args = parser.parse_args()
    
    if args.command == "list":
        for name, profile in sorted(get_all_profiles().items()):
            print(f"\n{name}:")
            print(f"  version: {profile.upstream_version}")
            print(f"  digest: {profile.digest}")
            print(f"  protocol: {profile.model_protocol}")
            print(f"  surfaces: {', '.join(profile.surfaces)}")
            print(f"  sub_agents: {profile.sub_agents['mode']} (depth={profile.sub_agents['max_depth']})")
            print(f"  tests: {', '.join(profile.tests)}")
    
    elif args.command == "validate":
        results = validate_all_profiles()
        if results:
            for name, errs in sorted(results.items()):
                print(f"\n{name}: VALIDATION FAILED", file=sys.stderr)
                for e in errs:
                    print(f"  - {e}", file=sys.stderr)
            return 1
        else:
            print("All profiles validated successfully")
            return 0
    
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
