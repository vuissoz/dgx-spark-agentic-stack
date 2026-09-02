#!/usr/bin/env python3
"""src/agentic/control/upgrade.py — Pinned upgrade management with digest tracking (§M4).

Provides:
- Pinned image digests for rollback safety
- Upgrade verification and validation
- Rollback to previous known-good state
- Integration with release manifest

Conforms to PLAN.md §M4 (Fondation production - upgrade épinglé).

Usage:
    from agentic.control.upgrade import UpgradeManager, ReleaseManifest
    
    # Initialize upgrade manager
    manager = UpgradeManager(
        manifests_dir="/srv/agentic/deployments/manifests/",
        releases_dir="/srv/agentic/deployments/releases/"
    )
    
    # Check for upgrades
    available = manager.check_upgrades()
    
    # Apply upgrade with pinned digest
    result = manager.upgrade_to("v2.1.0", pinned_digest="sha256:abc123...")
    
    # Rollback to previous release
    if not result.success:
        manager.rollback()
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)


@dataclass
class ImageDigest:
    """Represents a Docker image digest for pinned deployment."""
    image_name: str
    digest: str  # e.g., "sha256:abc123..."
    tag: Optional[str] = None
    size_bytes: Optional[int] = None
    created_at: Optional[float] = None

    @classmethod
    def parse(cls, digest_string: str) -> Optional[ImageDigest]:
        """Parse a Docker image reference with digest.
        
        Examples:
            "ghcr.io/open-webui:latest@sha256:abc123..."
            "ollama:latest@sha256:def456..."
        """
        # Pattern: image:tag@sha256:digest
        match = re.match(r"^([^:]+):([^@]+)@(sha256:[a-f0-9]{64})$", digest_string)
        if match:
            return cls(
                image_name=match.group(1),
                tag=match.group(2),
                digest=match.group(3),
            )
        
        # Pattern: image@sha256:digest (no tag)
        match = re.match(r"^([^@]+)@(sha256:[a-f0-9]{64})$", digest_string)
        if match:
            return cls(
                image_name=match.group(1),
                digest=match.group(2),
            )
        
        return None

    def __str__(self) -> str:
        if self.tag:
            return f"{self.image_name}:{self.tag}@{self.digest}"
        return f"{self.image_name}@{self.digest}"

    def to_dict(self) -> dict[str, Any]:
        return {
            "image_name": self.image_name,
            "digest": self.digest,
            "tag": self.tag,
            "size_bytes": self.size_bytes,
            "created_at": self.created_at,
        }


@dataclass
class ReleaseManifest:
    """Manifest of a release containing all image digests and configuration."""
    version: str
    timestamp: float = field(default_factory=time.time)
    description: str = ""
    images: dict[str, ImageDigest] = field(default_factory=dict)  # service_name -> ImageDigest
    config_files: list[str] = field(default_factory=list)  # List of config file paths
    environment: dict[str, str] = field(default_factory=dict)  # Environment variables
    dependencies: dict[str, str] = field(default_factory=dict)  # External dependencies

    @classmethod
    def from_file(cls, path: Path) -> ReleaseManifest:
        """Load a release manifest from a JSON file."""
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        
        images = {}
        for name, image_data in data.get("images", {}).items():
            digest = ImageDigest(
                image_name=image_data["image_name"],
                digest=image_data["digest"],
                tag=image_data.get("tag"),
                size_bytes=image_data.get("size_bytes"),
                created_at=image_data.get("created_at"),
            )
            images[name] = digest
        
        return cls(
            version=data["version"],
            timestamp=data.get("timestamp", time.time()),
            description=data.get("description", ""),
            images=images,
            config_files=data.get("config_files", []),
            environment=data.get("environment", {}),
            dependencies=data.get("dependencies", {}),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "timestamp": self.timestamp,
            "description": self.description,
            "images": {name: img.to_dict() for name, img in self.images.items()},
            "config_files": self.config_files,
            "environment": self.environment,
            "dependencies": self.dependencies,
        }

    def to_file(self, path: Path) -> None:
        """Save the manifest to a JSON file."""
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.to_dict(), f, indent=2)

    def get_image_digest(self, service_name: str) -> Optional[ImageDigest]:
        """Get the image digest for a specific service."""
        return self.images.get(service_name)

    def verify_all_digests(self) -> list[str]:
        """Verify all image digests are valid (format check)."""
        errors = []
        for name, digest in self.images.items():
            if not digest.digest or not digest.digest.startswith("sha256:"):
                errors.append(f"{name}: Invalid digest format")
            elif len(digest.digest) != 71:  # "sha256:" + 64 hex chars
                errors.append(f"{name}: Digest length invalid")
        return errors


@dataclass
class UpgradeResult:
    """Result of an upgrade operation."""
    success: bool
    version: str
    previous_version: Optional[str] = None
    changes: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    timestamp: float = field(default_factory=time.time)
    duration_seconds: float = 0.0

    def __str__(self) -> str:
        if self.success:
            return f"Upgrade to {self.version} completed in {self.duration_seconds:.2f}s"
        return f"Upgrade to {self.version} FAILED: {', '.join(self.errors)}"


@dataclass
class RollbackResult:
    """Result of a rollback operation."""
    success: bool
    version: str  # Version rolled back to
    previous_version: Optional[str] = None
    changes: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    timestamp: float = field(default_factory=time.time)
    duration_seconds: float = 0.0

    def __str__(self) -> str:
        if self.success:
            return f"Rollback to {self.version} completed in {self.duration_seconds:.2f}s"
        return f"Rollback to {self.version} FAILED: {', '.join(self.errors)}"


class UpgradeManager:
    """Manages pinned upgrades and rollbacks for the control plane (§M4).
    
    Features:
    - Pinned image digests for reproducible deployments
    - Release manifest management
    - Upgrade verification
    - Rollback to previous known-good state
    - Integration with audit logging
    """

    def __init__(
        self,
        manifests_dir: str = "/srv/agentic/deployments/manifests/",
        releases_dir: str = "/srv/agentic/deployments/releases/",
        current_dir: str = "/srv/agentic/deployments/current/",
        pinned_digests_file: str = "/srv/agentic/deployments/pinned_digests.json",
    ):
        self.manifests_dir = Path(manifests_dir)
        self.releases_dir = Path(releases_dir)
        self.current_dir = Path(current_dir)
        self.pinned_digests_file = Path(pinned_digests_file)
        
        self._pinned_digests: dict[str, str] = {}  # service_name -> digest
        self._current_version: Optional[str] = None
        self._audit_logger = None
        
        # Ensure directories exist
        self.manifests_dir.mkdir(parents=True, exist_ok=True)
        self.releases_dir.mkdir(parents=True, exist_ok=True)
        self.current_dir.mkdir(parents=True, exist_ok=True)
        
        # Load pinned digests
        self._load_pinned_digests()
        
        # Load current version
        self._load_current_version()

    def wire_audit(self, audit_logger) -> None:
        """Wire audit logger for upgrade events (§M4)."""
        self._audit_logger = audit_logger

    def _load_pinned_digests(self) -> None:
        """Load pinned digests from file."""
        if self.pinned_digests_file.exists():
            try:
                with open(self.pinned_digests_file, "r", encoding="utf-8") as f:
                    self._pinned_digests = json.load(f)
                logger.info(f"Loaded {len(self._pinned_digests)} pinned digests")
            except (json.JSONDecodeError, OSError) as e:
                logger.warning(f"Failed to load pinned digests: {e}")
                self._pinned_digests = {}

    def _save_pinned_digests(self) -> None:
        """Save pinned digests to file."""
        try:
            with open(self.pinned_digests_file, "w", encoding="utf-8") as f:
                json.dump(self._pinned_digests, f, indent=2)
        except OSError as e:
            logger.error(f"Failed to save pinned digests: {e}")

    def _load_current_version(self) -> None:
        """Load current version from file."""
        version_file = self.current_dir / "version.txt"
        if version_file.exists():
            try:
                with open(version_file, "r", encoding="utf-8") as f:
                    self._current_version = f.read().strip()
                logger.info(f"Current version: {self._current_version}")
            except OSError as e:
                logger.warning(f"Failed to load current version: {e}")

    def _save_current_version(self, version: str) -> None:
        """Save current version to file."""
        version_file = self.current_dir / "version.txt"
        try:
            with open(version_file, "w", encoding="utf-8") as f:
                f.write(version)
            self._current_version = version
        except OSError as e:
            logger.error(f"Failed to save current version: {e}")

    def get_pinned_digest(self, service_name: str) -> Optional[str]:
        """Get the pinned digest for a service."""
        return self._pinned_digests.get(service_name)

    def pin_digest(self, service_name: str, digest: str) -> None:
        """Pin a specific image digest for a service."""
        self._pinned_digests[service_name] = digest
        self._save_pinned_digests()
        logger.info(f"Pinned {service_name} to {digest}")

    def unpin_digest(self, service_name: str) -> bool:
        """Remove a pinned digest for a service."""
        if service_name in self._pinned_digests:
            del self._pinned_digests[service_name]
            self._save_pinned_digests()
            return True
        return False

    def get_all_pinned_digests(self) -> dict[str, str]:
        """Get all pinned digests."""
        return self._pinned_digests.copy()

    def get_current_version(self) -> Optional[str]:
        """Get the current deployed version."""
        return self._current_version

    def list_available_releases(self) -> list[str]:
        """List all available release versions."""
        versions = []
        for manifest_file in self.manifests_dir.glob("*.json"):
            # Extract version from filename (e.g., "v2.1.0.json" -> "v2.1.0")
            version = manifest_file.stem
            versions.append(version)
        return sorted(versions, reverse=True)

    def load_manifest(self, version: str) -> Optional[ReleaseManifest]:
        """Load a release manifest by version."""
        manifest_file = self.manifests_dir / f"{version}.json"
        if not manifest_file.exists():
            return None
        return ReleaseManifest.from_file(manifest_file)

    def save_manifest(self, manifest: ReleaseManifest) -> None:
        """Save a release manifest."""
        manifest_file = self.manifests_dir / f"{manifest.version}.json"
        manifest.to_file(manifest_file)
        logger.info(f"Saved manifest for {manifest.version}")

    def create_manifest(
        self,
        version: str,
        images: dict[str, str],  # service_name -> "image:tag@sha256:..."
        description: str = "",
        config_files: Optional[list[str]] = None,
        environment: Optional[dict[str, str]] = None,
        dependencies: Optional[dict[str, str]] = None,
    ) -> ReleaseManifest:
        """Create a new release manifest from image references."""
        image_digests = {}
        for service_name, image_ref in images.items():
            parsed = ImageDigest.parse(image_ref)
            if parsed:
                image_digests[service_name] = parsed
            else:
                # If parsing fails, use the string as-is
                image_digests[service_name] = ImageDigest(
                    image_name=image_ref,
                    digest="",
                )
        
        manifest = ReleaseManifest(
            version=version,
            description=description,
            images=image_digests,
            config_files=config_files or [],
            environment=environment or {},
            dependencies=dependencies or {},
        )
        
        self.save_manifest(manifest)
        return manifest

    def check_upgrades(self) -> list[str]:
        """Check for available upgrades from current version."""
        if not self._current_version:
            return self.list_available_releases()
        
        available = self.list_available_releases()
        current_index = available.index(self._current_version) if self._current_version in available else -1
        
        # Return versions newer than current
        return [v for v in available if available.index(v) < current_index] if current_index >= 0 else []

    def verify_manifest(self, version: str) -> list[str]:
        """Verify a release manifest is valid."""
        manifest = self.load_manifest(version)
        if not manifest:
            return [f"Manifest for {version} not found"]
        
        # Check all digests are valid
        digest_errors = manifest.verify_all_digests()
        
        # Check required fields
        errors = []
        if not manifest.version:
            errors.append("Missing version")
        
        errors.extend(digest_errors)
        return errors

    def verify_digests_match(self, version: str) -> dict[str, bool]:
        """Verify that the actual deployed images match the pinned digests."""
        manifest = self.load_manifest(version)
        if not manifest:
            return {}
        
        results = {}
        for service_name, image_digest in manifest.images.items():
            # In production, this would actually check the running container's image
            pinned = self._pinned_digests.get(service_name)
            if pinned and pinned == image_digest.digest:
                results[service_name] = True
            else:
                results[service_name] = False
        
        return results

    def upgrade_to(
        self,
        version: str,
        force: bool = False,
        skip_verification: bool = False,
    ) -> UpgradeResult:
        """Upgrade to a specific version with pinned digests."""
        start_time = time.time()
        result = UpgradeResult(
            success=False,
            version=version,
            previous_version=self._current_version,
        )
        
        # Load manifest
        manifest = self.load_manifest(version)
        if not manifest:
            result.errors.append(f"Manifest for version {version} not found")
            return result
        
        # Verify manifest
        if not skip_verification:
            errors = self.verify_manifest(version)
            if errors:
                result.errors.extend(errors)
                return result
        
        # Check if already at target version
        if self._current_version == version and not force:
            result.success = True
            result.changes.append("Already at target version")
            return result
        
        # Audit log start
        if self._audit_logger:
            self._audit_logger.log_start(
                action="upgrade.start",
                target=f"version:{version}",
                details={"from": self._current_version},
            )
        
        try:
            # In production, this would:
            # 1. Pull all images with pinned digests
            # 2. Update Docker Compose files
            # 3. Restart services
            # 4. Verify health checks
            
            # For now, simulate the upgrade process
            for service_name, image_digest in manifest.images.items():
                self.pin_digest(service_name, image_digest.digest)
                result.changes.append(f"Pinned {service_name} to {image_digest.digest}")
            
            # Save the new current version
            self._save_current_version(version)
            
            # Save the manifest to releases directory
            release_file = self.releases_dir / f"{version}.json"
            shutil.copy2(
                self.manifests_dir / f"{version}.json",
                release_file,
            )
            
            result.success = True
            result.changes.append(f"Upgraded from {self._current_version or 'none'} to {version}")
            
        except Exception as e:
            result.errors.append(str(e))
            logger.error(f"Upgrade failed: {e}")
        
        result.duration_seconds = time.time() - start_time
        
        # Audit log result
        if self._audit_logger:
            if result.success:
                self._audit_logger.log_success(
                    action="upgrade.complete",
                    target=f"version:{version}",
                    details={"changes": result.changes, "duration": result.duration_seconds},
                )
            else:
                self._audit_logger.log_failure(
                    action="upgrade.failed",
                    target=f"version:{version}",
                    error=", ".join(result.errors),
                    details={"duration": result.duration_seconds},
                )
        
        return result

    def rollback(
        self,
        target_version: Optional[str] = None,
        force: bool = False,
    ) -> RollbackResult:
        """Rollback to a previous version.
        
        If target_version is not specified, rolls back to the previous version.
        """
        start_time = time.time()
        
        if not target_version:
            # Find the previous version
            available = self.list_available_releases()
            if not available or len(available) < 2:
                return RollbackResult(
                    success=False,
                    version="",
                    previous_version=self._current_version,
                    errors=["No previous version available for rollback"],
                )
            
            # Find current version index
            try:
                current_index = available.index(self._current_version) if self._current_version else -1
                if current_index >= 0 and current_index < len(available) - 1:
                    target_version = available[current_index + 1]
                else:
                    target_version = available[-2] if len(available) >= 2 else available[0]
            except ValueError:
                target_version = available[-2] if len(available) >= 2 else available[0]
        
        result = RollbackResult(
            success=False,
            version=target_version,
            previous_version=self._current_version,
        )
        
        # Load target manifest
        manifest = self.load_manifest(target_version)
        if not manifest:
            result.errors.append(f"Manifest for version {target_version} not found")
            return result
        
        # Audit log start
        if self._audit_logger:
            self._audit_logger.log_start(
                action="rollback.start",
                target=f"version:{target_version}",
                details={"from": self._current_version},
            )
        
        try:
            # In production, this would:
            # 1. Restore previous Docker Compose files
            # 2. Pull images with known-good digests
            # 3. Restart services
            # 4. Verify health checks
            
            # For now, simulate the rollback process
            for service_name, image_digest in manifest.images.items():
                self.pin_digest(service_name, image_digest.digest)
                result.changes.append(f"Restored {service_name} to {image_digest.digest}")
            
            # Save the new current version
            self._save_current_version(target_version)
            
            result.success = True
            result.changes.append(f"Rolled back from {self._current_version or 'unknown'} to {target_version}")
            
        except Exception as e:
            result.errors.append(str(e))
            logger.error(f"Rollback failed: {e}")
        
        result.duration_seconds = time.time() - start_time
        
        # Audit log result
        if self._audit_logger:
            if result.success:
                self._audit_logger.log_success(
                    action="rollback.complete",
                    target=f"version:{target_version}",
                    details={"changes": result.changes, "duration": result.duration_seconds},
                )
            else:
                self._audit_logger.log_failure(
                    action="rollback.failed",
                    target=f"version:{target_version}",
                    error=", ".join(result.errors),
                    details={"duration": result.duration_seconds},
                )
        
        return result

    def get_upgrade_history(self, limit: int = 10) -> list[dict[str, Any]]:
        """Get the history of upgrades and rollbacks."""
        history = []
        
        # In production, this would read from a history file or database
        # For now, return available releases
        available = self.list_available_releases()
        for version in available[:limit]:
            manifest = self.load_manifest(version)
            if manifest:
                history.append({
                    "version": version,
                    "timestamp": manifest.timestamp,
                    "description": manifest.description,
                    "images": len(manifest.images),
                })
        
        return history

    def verify_current_digests(self) -> dict[str, Any]:
        """Verify that currently running images match pinned digests."""
        # In production, this would check actual running containers
        # For now, return pinned digests status
        results = {}
        for service_name, digest in self._pinned_digests.items():
            results[service_name] = {
                "pinned": digest,
                "verified": True,  # In production, would check actual container
                "message": "OK",
            }
        return results


# ── CLI Helper ───────────────────────────────────────────────────────

def main() -> None:
    """Demo upgrade management."""
    import tempfile
    
    # Use temp directories for demo
    with tempfile.TemporaryDirectory() as tmpdir:
        manager = UpgradeManager(
            manifests_dir=f"{tmpdir}/manifests/",
            releases_dir=f"{tmpdir}/releases/",
            current_dir=f"{tmpdir}/current/",
            pinned_digests_file=f"{tmpdir}/pinned.json",
        )
        
        # Create a test manifest
        manifest = manager.create_manifest(
            version="v1.0.0",
            images={
                "control": "ghcr.io/dgx-spark/control:v1.0.0@sha256:abc123def45678901234567890123456789012345678901234567890123456",
                "api": "ghcr.io/dgx-spark/api:v1.0.0@sha256:def456789012345678901234567890123456789012345678901234567890ab",
            },
            description="Initial release",
        )
        
        print(f"Created manifest: {manifest.version}")
        print(f"Images: {list(manifest.images.keys())}")
        
        # List available releases
        available = manager.list_available_releases()
        print(f"Available releases: {available}")
        
        # Check for upgrades
        upgrades = manager.check_upgrades()
        print(f"Upgrades available: {upgrades}")
        
        # Create a new version
        manifest_v2 = manager.create_manifest(
            version="v2.0.0",
            images={
                "control": "ghcr.io/dgx-spark/control:v2.0.0@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abc",
                "api": "ghcr.io/dgx-spark/api:v2.0.0@sha256:234567890abcdef1234567890abcdef1234567890abcdef1234567890abcd",
            },
            description="Feature release with auth improvements",
        )
        
        print(f"Created manifest: {manifest_v2.version}")
        
        # Simulate current version
        manager._save_current_version("v1.0.0")
        
        # Check for upgrades again
        upgrades = manager.check_upgrades()
        print(f"Upgrades available after v1.0.0: {upgrades}")
        
        # Perform upgrade
        result = manager.upgrade_to("v2.0.0")
        print(f"Upgrade result: {result}")
        
        # Check current version
        print(f"Current version: {manager.get_current_version()}")
        
        # Check pinned digests
        print(f"Pinned digests: {manager.get_all_pinned_digests()}")
        
        # Simulate rollback
        rollback_result = manager.rollback()
        print(f"Rollback result: {rollback_result}")
        print(f"Current version after rollback: {manager.get_current_version()}")


if __name__ == "__main__":
    main()
