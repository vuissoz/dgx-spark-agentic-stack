#!/usr/bin/env python3
"""src/agentic/control/sbom_provenance.py — SBOM, provenance capture and image allowlist (PLAN §17).

This module:
1. Scans all compose files for image references and resolves concrete digests;
2. Records dependency versions from requirements.txt / pyproject.toml;
3. Validates resolved images against an approved allowlist;
4. Writes a structured SBOM JSON artifact.

Conforms to PLAN.md §17 (Update et exploitation) — versions épinglées,
SBOM, provenance and scan requirements.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional


@dataclass

class ImageDigest:
    """Resolved image reference with tag and digest."""
    name: str          # e.g., "ollama/ollama"
    tag: str           # e.g., "latest"
    digest: str = ""   # e.g., "sha256:abc..."


@dataclass
class SBOMArtifact:
    """Complete SBOM artifact for a release."""
    schema_version: str = "agentic.sbom.v1"
    generated_at: float = field(default_factory=time.time)
    repo_root: str = ""
    compose_images: list[ImageDigest] = field(default_factory=list)
    python_deps: dict[str, str] = field(default_factory=dict)
    npm_specs: dict[str, str] = field(default_factory=dict)
    allowlist_pass: bool = True
    allowlist_failures: list[str] = field(default_factory=list)

    def to_json(self, indent: int = 2) -> str:
        """Serialize SBOM artifact to JSON."""
        return json.dumps({
            "schema_version": self.schema_version,
            "generated_at": self.generated_at,
            "repo_root": self.repo_root,
            "compose_images": [img.__dict__ for img in self.compose_images],
            "python_deps": self.python_deps,
            "npm_specs": self.npm_specs,
            "allowlist_pass": self.allowlist_pass,
            "allowlist_failures": self.allowlist_failures,
        }, indent=indent)

    def summary(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "compose_images_count": len(self.compose_images),
            "python_deps_count": len(self.python_deps),
            "npm_specs_count": len(self.npm_specs),
            "allowlist_pass": self.allowlist_pass,
            "allowlist_failures": self.allowlist_failures,
        }


class SBOMScanner:
    """Scans compose files and dependency manifests for SBOM artifact generation."""

    def _find_repo_root(self) -> str:
        """Find the project root by searching for compose/ directory."""
        # Start from CWD and walk up, also check path-based fallback
        candidates = [os.getcwd()]
        
        # Path-based fallback: go up from this module's location
        p = Path(__file__).resolve()
        while p.parent != p:  # Don't go past root filesystem
            candidates.append(str(p))
            p = p.parent
        
        # Also try the parent of src/ (common layout)
        for c in list(candidates):
            parent = os.path.dirname(c)
            if parent and parent not in candidates:
                candidates.append(parent)

        for candidate in candidates:
            if os.path.isdir(os.path.join(candidate, "compose")):
                return candidate
        
        # Final fallback: use the first candidate (typically CWD)
        return candidates[0]

    def __init__(self, repo_root: Optional[str] = None):
        self.repo_root = repo_root or self._find_repo_root()

    def find_compose_files(self) -> list[str]:
        """Find all compose files in the project."""
        compose_dir = os.path.join(self.repo_root, "compose")
        if not os.path.isdir(compose_dir):
            return []
        files = []
        for f in sorted(os.listdir(compose_dir)):
            if f.endswith(".yml") or f.endswith(".yaml"):
                files.append(os.path.join(compose_dir, f))
        return files

    def extract_images_from_compose(self) -> list[ImageDigest]:
        """Extract image references from compose files using python yaml parsing."""
        images = []
        for cf in self.find_compose_files():
            try:
                with open(cf) as fh:
                    content = fh.read()
                # Match image: lines (not build-only or variable-only entries)
                for line in content.split("\n"):
                    stripped = line.strip()
                    m = re.match(r'^image:\s*["\']?([^"\':\s#]+)(?:[:\$"]+)?(\w*)', stripped)
                    if m:
                        name = m.group(1)
                        tag = m.group(2) if m.group(2) else "latest"
                        if not name.startswith("$"):  # Skip variable references
                            images.append(ImageDigest(name=name, tag=tag))
            except Exception:
                pass  # Best-effort scan

        # Deduplicate by (name, tag)
        seen = set()
        unique = []
        for img in images:
            key = f"{img.name}:{img.tag}"
            if key not in seen:
                seen.add(key)
                unique.append(img)
        return unique

    def extract_python_deps(self) -> dict[str, str]:
        """Extract Python dependency versions from requirements.txt / pyproject.toml."""
        deps = {}
        req_paths = [
            "src/requirements-control.txt",
            "deployments/gate/requirements.txt",
        ]
        for rel in req_paths:
            path = os.path.join(self.repo_root, rel)
            if os.path.isfile(path):
                with open(path) as fh:
                    for line in fh:
                        line = line.strip()
                        if not line or line.startswith("#") or line.startswith("-"):
                            continue
                        m = re.match(r'^([a-zA-Z0-9_-]+)\s*(?:[>=<!~]+\s*(\S+))?\s*$', line)
                        if m:
                            deps[m.group(1)] = m.group(2) or "*"

        # Also check pyproject.toml files (basic parsing)
        for root, dirs, files in os.walk(self.repo_root):
            if ".runtime" in root or "__pycache__" in root:
                continue
            if "pyproject.toml" in files:
                toml_path = os.path.join(root, "pyproject.toml")
                with open(toml_path) as fh:
                    content = fh.read()
                for m in re.finditer(r'"([^"]+)"\s*=\s*"([^"]+)"', content):
                    name, version = m.group(1), m.group(2)
                    if "build-system" not in content[:m.start()].split("\n")[-3:]:
                        deps[name] = version

        return deps

    def resolve_digests(self, images: Optional[list[ImageDigest]] = None) -> None:
        """Attempt to resolve image digests via docker inspect."""
        imgs = images or getattr(self, 'compose_images', [])
        for img in imgs:
            try:
                result = subprocess.run(
                    ["docker", "inspect", "--format", "{{index .RepoDigests 0}}",
                     f"{img.name}:{img.tag}"],
                    capture_output=True, text=True, timeout=15,
                )
                digest = result.stdout.strip()
                if digest:
                    img.digest = digest
            except (subprocess.TimeoutExpired, FileNotFoundError):
                pass  # No docker or network available

    def scan_all(self) -> SBOMArtifact:
        """Perform full SBOM scan and return artifact."""
        artifact = SBOMArtifact(repo_root=self.repo_root)
        self.compose_images = self.extract_images_from_compose()  # Store on instance for resolve_digests
        artifact.compose_images = self.compose_images
        artifact.python_deps = self.extract_python_deps()
        self.resolve_digests(self.compose_images)  # Best-effort, won't fail if docker unavailable
        return artifact


class ImageAllowlistValidator:
    """Validates resolved images against an approved allowlist file.

    Per §17: versions and digests épinglées, aucune mise à jour automatique de production.
    The allowlist format is one image per line: "name:tag@digest" or "name:tag".
    """

    def __init__(self):
        self._allowlist: dict[str, str] = {}  # name:tag → digest (optional)

    def load_allowlist(self, path: str) -> None:
        """Load allowlist from file. One entry per line."""
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                # Format: name:tag@digest or name:tag
                m = re.match(r'^([^:@]+):([^\s@]+)(?:@(.+))?$', line)
                if m:
                    key = f"{m.group(1)}:{m.group(2)}"
                    self._allowlist[key] = m.group(3) or ""

    def validate_artifact(self, artifact: SBOMArtifact) -> bool:
        """Validate an SBOM artifact against the allowlist."""
        failures = []
        for img in artifact.compose_images:
            key = f"{img.name}:{img.tag}"
            if key not in self._allowlist:
                # Image not in allowlist — this is a failure (strict mode)
                failures.append(f"Image not in allowlist: {key}")
            elif self._allowlist[key]:  # Digest specified and must match
                expected = self._allowlist[key]
                if img.digest != expected:
                    failures.append(
                        f"Digest mismatch for {key}: expected={expected} got={img.digest or '(not resolved)'}"
                    )

        artifact.allowlist_pass = len(failures) == 0
        artifact.allowlist_failures = failures
        return artifact.allowlist_pass


# ── CLI Helper ────────────────────────────────────────────────────────

def main() -> None:
    """SBOM scan CLI — mirrors scripts/sbom_provenance.sh but in Python."""
    import argparse

    parser = argparse.ArgumentParser(description="SBOM & Provenance Scanner (§17)")
    subparsers = parser.add_subparsers(dest="command")

    # scan command
    p_scan = subparsers.add_parser("scan", help="Scan compose and dependencies for SBOM")
    p_scan.add_argument("--output-dir", default=None, help="Output directory for JSON artifact")

    # validate command
    p_validate = subparsers.add_parser("validate", help="Validate images against allowlist")
    p_validate.add_argument("sbom_json", help="SBOM JSON file to validate")
    p_validate.add_argument("--allowlist", required=True, help="Allowlist file path")

    args = parser.parse_args()
    scanner = SBOMScanner()

    if args.command == "scan":
        artifact = scanner.scan_all()
        output_file = os.path.join(args.output_dir or ".", "sbom.json")
        with open(output_file, "w") as f:
            f.write(artifact.to_json())
        print(f"SBOM written to {output_file}")
        print(json.dumps(artifact.summary(), indent=2))

    elif args.command == "validate":
        with open(args.sbom_json) as f:
            data = json.load(f)
        # Reconstruct artifact (simplified — just validate images)
        validator = ImageAllowlistValidator()
        validator.load_allowlist(args.allowlist)

        class MockArtifact:
            compose_images = [ImageDigest(**img.__dict__) for img in data.get("compose_images", [])]
            allowlist_pass = True
            allowlist_failures = []

        mock = MockArtifact()
        passed = validator.validate_artifact(mock)
        print(f"Validate: {'PASS' if passed else 'FAIL'}")
        for f in mock.allowlist_failures:
            print(f"  FAIL: {f}")

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
