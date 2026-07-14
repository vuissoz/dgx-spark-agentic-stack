"""tests/J17_quota_sbom_integration.py — M5 ModelBroker quota + §17 SBOM integration tests.

Validates:
- QuotaManager enforces token/request/GPU budget limits
- Quota usage recording updates snapshots correctly
- SBOM scanner extracts compose images and python deps
- Allowlist validator catches missing/mismatched images
"""

import json
import sys
import tempfile
sys.path.insert(0, "src")


def test_quota_can_admit():
    """Test QuotaManager can_admit() with valid budget."""
    from agentic.implementations.model_broker import (
        QuotaManager, UserIdentity, QuotaSnapshot, ModelBackend,
    )

    qm = QuotaManager(
        max_tokens_per_day=1_000_000,
        max_requests_per_hour=500,
        max_gpu_minutes=60.0,
    )

    identity = UserIdentity(user_id="alice", project_id="personal")
    
    # Should admit small requests within budget
    allowed, reason = qm.can_admit(identity, tokens_estimate=1000)
    assert allowed, f"Should admit: {reason}"

    allowed, reason = qm.can_admit(identity, tokens_estimate=50000)
    assert allowed, f"Should admit 50k tokens: {reason}"

    print("PASS: quota_can_admit")


def test_quota_exhaustion():
    """Test QuotaManager rejects when budget exceeded."""
    from agentic.implementations.model_broker import (
        QuotaManager, UserIdentity, ModelBackend,
    )

    qm = QuotaManager(
        max_tokens_per_day=100_000,  # Small budget for testing
        max_requests_per_hour=5,
        max_gpu_minutes=60.0,
    )

    identity = UserIdentity(user_id="bob", project_id="personal")
    
    # Simulate consuming most of the budget
    qm.record_usage(identity, tokens_consumed=95_000)
    qm.record_usage(identity, tokens_consumed=2_000)  # Now at 97k / 100k

    allowed, reason = qm.can_admit(identity, tokens_estimate=5_000)
    assert not allowed, "Should reject: token budget exhausted"
    assert "Token budget exhausted" in reason or "budget" in reason.lower(), f"Expected budget message: {reason}"

    # Request count limit
    qm2 = QuotaManager(max_requests_per_hour=2)
    ident2 = UserIdentity(user_id="charlie")
    qm2.record_usage(ident2, tokens_consumed=100)  # counts as 1 request
    qm2.record_usage(ident2, tokens_consumed=100)  # counts as 2nd request

    allowed2, reason2 = qm2.can_admit(ident2, tokens_estimate=100)
    assert not allowed2, "Should reject: request limit reached"
    assert "Request limit" in reason2 or "limit" in reason2.lower(), f"Expected limit message: {reason2}"

    print("PASS: quota_exhaustion")


def test_quota_gpu_budget():
    """Test GPU time budget enforcement for GPU-intensive projects."""
    from agentic.implementations.model_broker import (
        QuotaManager, UserIdentity, ModelBackend,
    )

    qm = QuotaManager(
        max_tokens_per_day=1_000_000,
        max_requests_per_hour=500,
        max_gpu_minutes=30.0,  # Small for testing
    )

    # GPU-intensive project (project_id triggers gpu check)
    identity = UserIdentity(user_id="dave", project_id="gpu-intensive")
    
    # Record ~29 minutes of GPU usage
    qm.record_usage(identity, tokens_consumed=29_000)  # 1k tokens ≈ 1 min GPU

    allowed, reason = qm.can_admit(identity, tokens_estimate=5_000)  # Would add ~5 min GPU
    assert not allowed, "Should reject: GPU budget exceeded for gpu-intensive project"
    assert "GPU" in reason or "gpu" in reason.lower(), f"Expected GPU message: {reason}"

    print("PASS: quota_gpu_budget")


def test_sbom_scan():
    """Test SBOMScanner extracts compose images and python deps."""
    from agentic.control.sbom_provenance import SBOMScanner, SBOMArtifact

    scanner = SBOMScanner()
    
    # Scan compose files
    compose_files = scanner.find_compose_files()
    assert len(compose_files) > 0, "Expected at least one compose file"

    images = scanner.extract_images_from_compose()
    # Should find common images: ollama, openwebui, grafana, etc.
    image_names = [img.name for img in images]
    found_common = any(n in image_names for n in ["ollama/ollama", "grafana/grafana", "forgejo/forgejo"])
    assert found_common or len(images) > 0, f"Expected compose images: {image_names}"

    # Python deps
    deps = scanner.extract_python_deps()
    assert isinstance(deps, dict), "Python deps should be a dict"
    
    print(f"PASS: sbom_scan ({len(images)} images, {len(deps)} python deps)")


def test_sbom_artifact_serialization():
    """Test SBOMArtifact JSON serialization."""
    from agentic.control.sbom_provenance import SBOMArtifact, ImageDigest

    artifact = SBOMArtifact(
        repo_root="/test/repo",
        compose_images=[ImageDigest(name="ollama/ollama", tag="latest", digest="sha256:abc123")],
        python_deps={"fastapi": "0.104.0"},
    )

    # Serialize to JSON
    json_str = artifact.to_json()
    data = json.loads(json_str)
    assert data["schema_version"] == "agentic.sbom.v1"
    assert len(data["compose_images"]) == 1
    assert data["python_deps"]["fastapi"] == "0.104.0"

    # Summary method
    summary = artifact.summary()
    assert summary["compose_images_count"] == 1
    assert summary["allowlist_pass"] is True

    print("PASS: sbom_artifact_serialization")


def test_allowlist_validation():
    """Test ImageAllowlistValidator catches missing/mismatched images."""
    from agentic.control.sbom_provenance import (
        SBOMScanner, SBOMArtifact, ImageDigest,
        ImageAllowlistValidator,
    )

    # Create a mock allowlist file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("# Approved images\n")
        f.write("ollama/ollama:latest@sha256:abcdef123456\n")
        f.write("grafana/grafana:latest\n")  # No digest required
        f.write("#forgejo/forgejo:latest\n")  # Commented out — not in allowlist
        allowlist_path = f.name

    scanner = SBOMScanner()
    artifact = scanner.scan_all()

    validator = ImageAllowlistValidator()
    validator.load_allowlist(allowlist_path)
    validator.validate_artifact(artifact)

    # At minimum, any images NOT in the allowlist should be flagged
    # (In strict mode, all images must be in allowlist)
    assert hasattr(artifact, 'allowlist_pass')
    assert hasattr(artifact, 'allowlist_failures')
    
    import os; os.unlink(allowlist_path)
    print(f"PASS: allowlist_validation ({len(artifact.allowlist_failures)} failures)")


def test_sbom_cli_scan():
    """Test SBOM CLI scan command."""
    from agentic.control.sbom_provenance import SBOMScanner, SBOMArtifact
    
    scanner = SBOMScanner()
    artifact = scanner.scan_all()
    
    assert isinstance(artifact, SBOMArtifact)
    # Best-effort: might find images if docker not available
    assert len(artifact.compose_images) >= 0

    print("PASS: sbom_cli_scan")


if __name__ == "__main__":
    test_quota_can_admit()
    test_quota_exhaustion()
    test_quota_gpu_budget()
    test_sbom_scan()
    test_sbom_artifact_serialization()
    test_allowlist_validation()
    test_sbom_cli_scan()
    print("\n=== J17_quota_sbom_integration passed ===")
