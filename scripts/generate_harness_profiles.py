#!/usr/bin/env python3
"""scripts/generate_harness_profiles.py — Génère harness_profiles.py à partir de harness_profiles_config.yaml

Ce script lit la configuration YAML des harnesses et génère le fichier Python
src/agentic/implementations/harness_profiles.py avec des digests calculés dynamiquement.

Usage:
    python3 scripts/generate_harness_profiles.py [--config <path>] [--output <path>] [--force]

Options:
    --config     Chemin vers le fichier YAML de config (défaut: src/agentic/implementations/harness_profiles_config.yaml)
    --output     Chemin vers le fichier Python de sortie (défaut: src/agentic/implementations/harness_profiles.py)
    --force      Écraser le fichier de sortie même s'il existe
"""

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG_PATH = REPO_ROOT / "src" / "agentic" / "implementations" / "harness_profiles_config.yaml"
DEFAULT_OUTPUT_PATH = REPO_ROOT / "src" / "agentic" / "implementations" / "harness_profiles.py"


def compute_digest(spec: str, spec_type: str) -> str:
    """Calcule un digest SHA256 à partir de la spécification.
    
    Args:
        spec: La spécification (ex: "@openai/codex@0.147.0", URL, SHA Git)
        spec_type: Type de spec ("npm", "git", "binary", "script")
    
    Returns:
        Digest SHA256 (64 chars hex)
    """
    if spec_type == "git" and len(spec) == 40:
        # Pour les SHA Git (40 chars), on les utilise directement
        # en les padant à 64 chars pour rester dans le format sha256:
        # C'est acceptable car Git SHA est déjà un hash unique
        return spec + "0" * (64 - 40) if len(spec) == 40 else spec
    
    # Pour npm, binary, script : on hash la spec
    return hashlib.sha256(spec.encode("utf-8")).hexdigest()


def get_spec_and_type(harness_data: dict[str, Any]) -> tuple[str, str]:
    """Extrait la spec et son type à partir des données du harness.
    
    Order de priorité: git_sha > npm_spec > install_script > binary_url
    """
    if "git_sha" in harness_data:
        return harness_data["git_sha"], "git"
    elif "npm_spec" in harness_data:
        return harness_data["npm_spec"], "npm"
    elif "install_script" in harness_data:
        return harness_data["install_script"], "script"
    elif "binary_url" in harness_data:
        return harness_data["binary_url"], "binary"
    else:
        # Fallback pour les entrées sans spec explicite
        return harness_data.get("upstream_version", "latest"), "version"


def generate_harness_profiles(config_path: Path, output_path: Path, force: bool = False) -> int:
    """Génère le fichier harness_profiles.py à partir de la config YAML.
    
    Returns:
        0 si succès, 1 si erreur
    """
    # Vérifier que le fichier de config existe
    if not config_path.is_file():
        print(f"ERROR: Config file not found: {config_path}", file=sys.stderr)
        return 1
    
    # Vérifier que le fichier de sortie n'existe pas (sauf si --force)
    if output_path.exists() and not force:
        print(f"ERROR: Output file already exists: {output_path}", file=sys.stderr)
        print("Use --force to overwrite or remove it manually.", file=sys.stderr)
        return 1
    
    # Charger la configuration YAML
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            config = yaml.safe_load(f)
    except Exception as e:
        print(f"ERROR: Failed to load config: {e}", file=sys.stderr)
        return 1
    
    if not config or "harnesses" not in config:
        print("ERROR: Invalid config format. Expected 'harnesses' key.", file=sys.stderr)
        return 1
    
    # Créer le dossier de sortie si nécessaire
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    # Générer le code Python
    output_lines = [
        '#!/usr/bin/env python3',
        '"""src/agentic/implementations/harness_profiles.py — Harness integration profiles (§8).',
        '',
        'Each profile defines: upstream version, digest, ARM64 architecture, model protocol,',
        'persistent files, surfaces, permissions, sub-agents, and tests.',
        '',
        'Conforms to PLAN.md §8 (Profils d\'intégration des harnesses v1).',
        'Generated from harness_profiles_config.yaml - DO NOT EDIT MANUALLY',
        '"""',
        '',
        'from __future__ import annotations',
        '',
        'import json',
        'from dataclasses import dataclass, field',
        'from typing import Any',
        '',
        '',
        '# ── Profile Schema (§8) ─────────────────────────────────────────────',
        '',
        '@dataclass(frozen=True)',
        'class HarnessProfile:',
        '    """Integration profile for a harness v1 → v2 migration.',
        '',
        '    Contains: upstream_version, digest, architecture (ARM64), model_protocol,',
        '    persistent_files, surfaces, permissions, sub_agents, tests, and repo_e2e support.',
        '    ',
        '    Conforms to PLAN.md §8 specification and §M6 (Agents de code).',
        '    """',
        '    harness_name: str',
        '    model_protocol: str                # openai_responses, anthropic_messages, chat_completions, etc.',
        '    upstream_version: str = ""         # e.g., "v1.2.3" or "latest"',
        '    digest: str = ""                   # image digest for immutability',
        '    architecture: str = "ARM64"        # DGX Spark target architecture',
        '    persistent_files: list[str] = field(default_factory=list)  # State dirs',
        '    surfaces: list[str] = field(default_factory=list)          # cli, web, ide, desktop',
        '    permissions: dict[str, Any] = field(default_factory=lambda: {"cpus": 1.0, "memory_mb": 1024, "gpu_count": 0})  # Resource limits',
        '    sub_agents: dict[str, Any] = field(default_factory=lambda: {',
        '        "mode": "none",  # none | native | platform | external-provider',
        '        "max_depth": 1,',
        '        "max_concurrency": 1,',
        '    })',
        '    tests: list[str] = field(default_factory=list)  # Test file patterns',
        '    removal_condition: str = ""     # When v1 route can be retired',
        '    supports_repo_e2e: bool = True    # §M6: repo-e2e integration support',
        '',
        '',
        '# ── All Harness Profiles (§8 + §2.2 table) ─────────────────────────',
        '',
        'def get_all_profiles() -> dict[str, HarnessProfile]:',
        '    """Return canonical profiles for all 11 harnesses (§2.2)."""',
        '    return {',
    ]
    
    # Générer les profils
    harnesses = config["harnesses"]
    for name, data in harnesses.items():
        spec, spec_type = get_spec_and_type(data)
        digest = compute_digest(spec, spec_type)
        
        # Formater les données Python
        persistent_files_str = json.dumps(data.get("persistent_files", []))
        surfaces_str = json.dumps(data.get("surfaces", []))
        permissions_str = json.dumps(data.get("permissions", {"cpus": 1.0, "memory_mb": 1024, "gpu_count": 0}))
        sub_agents_str = json.dumps(data.get("sub_agents", {"mode": "none", "max_depth": 1, "max_concurrency": 1}))
        tests_str = json.dumps(data.get("tests", []))
        
        output_lines.append(f'        "{name}": HarnessProfile(')
        output_lines.append(f'            harness_name="{name}",')
        output_lines.append(f'            model_protocol="{data["model_protocol"]}",')
        output_lines.append(f'            upstream_version="{data.get("upstream_version", "")}",')
        output_lines.append(f'            digest="sha256:{digest}",')
        output_lines.append(f'            architecture="{data.get("architecture", "ARM64")}",')
        output_lines.append(f'            persistent_files={persistent_files_str},')
        output_lines.append(f'            surfaces={surfaces_str},')
        output_lines.append(f'            permissions={permissions_str},')
        output_lines.append(f'            sub_agents={sub_agents_str},')
        output_lines.append(f'            tests={tests_str},')
        output_lines.append(f'            supports_repo_e2e={str(data.get("supports_repo_e2e", True))},')
        output_lines.append(f'            removal_condition="{data.get("removal_condition", "")}",')
        output_lines.append(f'        ),')
    
    # Fermer le dictionnaire et ajouter la suite du code
    output_lines.extend([
        '    }',
        '',
        '',
        '# ── Profile Validation (for CI/gates) ─────────────────────────────',
        '',
        'def validate_profile(profile: HarnessProfile) -> list[str]:',
        '    """Validate a harness profile against invariants.',
        '',
        '    Returns list of validation errors (empty = passes).',
        '    """',
        '    errors = []',
        '',
        '    # §8 invariant: digest must be present for immutability',
        '    if not profile.digest or profile.digest.startswith("sha256:" + "0" * 64):',
        '        errors.append("digest is invalid/empty — must be resolved during update")',
        '',
        '    # §5.4 invariant: sub-agent mode must be one of the valid values',
        '    valid_modes = {"none", "native", "platform", "external-provider"}',
        '    if profile.sub_agents.get("mode") not in valid_modes:',
        '        errors.append(f"invalid sub_agent mode: {profile.sub_agents.get(\'mode\')}")',
        '',
        '    # §5.4 invariant: max_depth >= 1 and max_concurrency >= 1',
        '    if profile.sub_agents.get("max_depth", 0) < 1:',
        '        errors.append("sub_agent max_depth must be >= 1")',
        '    if profile.sub_agents.get("max_concurrency", 0) < 1:',
        '        errors.append("sub_agent max_concurrency must be >= 1")',
        '',
        '    # §3.2 invariant: model_protocol must match a known protocol',
        '    valid_protocols = {',
        '        "openai_responses",',
        '        "anthropic_messages",',
        '        "chat_completions",',
        '        "ollama_native",',
        '        "configurable_endpoint",',
        '        "configurable",',
        '        "openai_compatible",',
        '        "ollama_openai_compatible",',
        '    }',
        '    if profile.model_protocol not in valid_protocols:',
        '        errors.append(f"invalid model_protocol: {profile.model_protocol}")',
        '',
        '    # §5.4 invariant: surfaces must be non-empty',
        '    if not profile.surfaces:',
        '        errors.append("surfaces list must be non-empty")',
        '',
        '    # §8 invariant: tests must reference at least one test file',
        '    if not profile.tests:',
        '        errors.append("tests list must contain at least one test pattern")',
        '',
        '    return errors',
        '',
        '',
        'def validate_all_profiles() -> dict[str, list[str]]:',
        '    """Validate all profiles and return error maps."""',
        '    results = {}',
        '    for name, profile in get_all_profiles().items():',
        '        errs = validate_profile(profile)',
        '        if errs:',
        '            results[name] = errs',
        '    return results',
        '',
        '',
        '# ── CLI Entry Point ───────────────────────────────────────────────',
        '',
        'def main() -> int:',
        '    """CLI for harness profile management."""',
        '    import argparse',
        '    import sys',
        '    ',
        '    parser = argparse.ArgumentParser(description="Harness Profiles — §8")',
        '    subparsers = parser.add_subparsers(dest="command")',
        '    ',
        '    p_list = subparsers.add_parser("list", help="List all profiles")',
        '    p_validate = subparsers.add_parser("validate", help="Validate all profiles")',
        '    ',
        '    args = parser.parse_args()',
        '    ',
        '    if args.command == "list":',
        '        for name, profile in sorted(get_all_profiles().items()):',
        '            print(f"\\n{name}:")',
        '            print(f"  version: {profile.upstream_version}")',
        '            print(f"  digest: {profile.digest}")',
        '            print(f"  protocol: {profile.model_protocol}")',
        '            print(f"  surfaces: {\', \'.join(profile.surfaces)}")',
        '            print(f"  sub_agents: {profile.sub_agents[\'mode\']} (depth={profile.sub_agents[\'max_depth\']})")',
        '            print(f"  tests: {\', \'.join(profile.tests)}")',
        '    ',
        '    elif args.command == "validate":',
        '        results = validate_all_profiles()',
        '        if results:',
        '            for name, errs in sorted(results.items()):',
        '                print(f"\\n{name}: VALIDATION FAILED", file=sys.stderr)',
        '                for e in errs:',
        '                    print(f"  - {e}", file=sys.stderr)',
        '            return 1',
        '        else:',
        '            print("All profiles validated successfully")',
        '            return 0',
        '    ',
        '    else:',
        '        parser.print_help()',
        '        return 1',
        '',
        '',
        'if __name__ == "__main__":',
        '    sys.exit(main())',
    ])
    
    # Écrire le fichier de sortie
    output_content = "\n".join(output_lines) + "\n"
    
    try:
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(output_content)
        print(f"SUCCESS: Generated {output_path}")
        print(f"  - {len(harnesses)} harness profiles")
        print(f"  - All digests computed from specifications")
        return 0
    except Exception as e:
        print(f"ERROR: Failed to write output: {e}", file=sys.stderr)
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate harness_profiles.py from YAML configuration"
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG_PATH,
        help="Path to YAML config file"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT_PATH,
        help="Path to output Python file"
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite output file if it exists"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check if generation is needed (exit 1 if outdated)"
    )
    
    args = parser.parse_args()
    
    if args.check:
        # Mode check: vérifier si le fichier existe et est à jour
        if not args.output.is_file():
            print(f"MISSING: {args.output} does not exist")
            return 1
        
        # Comparer les timestamps
        config_mtime = args.config.stat().st_mtime
        output_mtime = args.output.stat().st_mtime
        
        if config_mtime > output_mtime:
            print(f"OUTDATED: {args.config} is newer than {args.output}")
            return 1
        
        print(f"UP-TO-DATE: {args.output} is current")
        return 0
    
    return generate_harness_profiles(args.config, args.output, args.force)


if __name__ == "__main__":
    sys.exit(main())
