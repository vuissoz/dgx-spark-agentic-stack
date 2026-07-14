"""tests/J24_risk_extension_scanner.py — §9.3 Extensions à risque governance scanner.

Validates:
- Detection of Python execution vectors (Tools/Functions/Pipelines) in compose files
- Detection of unversioned/untracked ComfyUI custom nodes
- Detection of JupyterLab code environment exposure without isolation
- Requirements.txt scanning for unversioned dependencies
- Allowlist compliance reporting
- Empty scan produces valid report with 0 findings

Tests:
- J24-1: Scanner detects OPENWEBUI_TOOL execution enabled
- J24-2: Scanner detects ComfyUI custom node pip installation
- J24-3: Scanner detects JupyterLab running as root without isolation
- J24-4: Requirements.txt scanning catches unversioned dependencies
- J24-5: Allowlist compliance report is accurate
- J24-6: Clean scan (no risks) produces valid empty report
"""

import json
import os
import sys
import tempfile
sys.path.insert(0, "src")

from agentic.implementations.risk_extension_scanner import (
    RiskExtensionScanner, ScanReport, ScanFinding, 
    ExtensionAllowlist, RiskLevel, scan_application_risks,
)


def test_detect_op_webui_python_execution():
    """J24-1: Scanner detects OPENWEBUI_TOOL execution enabled.
    
    Verifies that the scanner correctly identifies OpenWebUI Tools/Functions/Pipelines
    configuration that enables Python execution inside containers.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        # Create a compose file with risky OpenWebUI config
        compose_path = os.path.join(tmpdir, "compose.test.yml")
        with open(compose_path, "w") as f:
            f.write("""services:
  openwebui:
    image: ghcr.io/open-webui/open-webui:latest
    environment:
      OPENWEBUI_TOOL_EXECUTION_ENABLED="true"
      RAG_ENABLED="false"
""")
        
        scanner = RiskExtensionScanner(repo_root=tmpdir)
        findings = scanner.scan_compose_for_python_execution(compose_path)
        
        # Should detect the risky pattern
        assert len(findings) >= 1, \
            f"Should detect Python execution risk, found: {findings}"
        
        finding = findings[0]
        assert finding.category == "python_execution", \
            f"Category should be python_execution: {finding.category}"
        assert finding.severity in [RiskLevel.HIGH, RiskLevel.MEDIUM], \
            f"Severity should be HIGH or MEDIUM: {finding.severity}"
        
        print("PASS: J24-1_detect_op_webui_python_execution")


def test_detect_comfyui_custom_node_install():
    """J24-2: Scanner detects ComfyUI custom node pip installation.
    
    Verifies that the scanner correctly identifies unversioned/custom nodes
    that are installed via pip or git clone without version pinning.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        compose_path = os.path.join(tmpdir, "compose.test.yml")
        with open(compose_path, "w") as f:
            f.write("""services:
  comfyui:
    image: ghcr.io/comfyanonymous/comfyui:latest
    volumes:
      - ./custom_nodes:/app/custom_nodes:r,w
    command: |
      pip install custom-nodes-for-comfyui
      git clone https://github.com/example/comfyui-node.git /app/custom_nodes/node
""")
        
        scanner = RiskExtensionScanner(repo_root=tmpdir)
        findings = scanner.scan_compose_for_custom_nodes(compose_path)
        
        # Should detect unversioned node installation
        assert len(findings) >= 1, \
            f"Should detect unversioned node risk, found: {findings}"
        
        finding = findings[0]
        assert finding.category == "unversioned_node", \
            f"Category should be unversioned_node: {finding.category}"
        
        print("PASS: J24-2_detect_comfyui_custom_node_install")


def test_detect_jupyterlab_root_access():
    """J24-3: Scanner detects JupyterLab running as root without isolation.
    
    Verifies that JupyterLab configurations with --allow-root or hardcoded
    tokens are flagged as security risks per §9.3.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        compose_path = os.path.join(tmpdir, "compose.test.yml")
        with open(compose_path, "w") as f:
            f.write("""services:
  jupyterlab:
    image: jupyter/base-notebook:latest
    command: jupyter lab --allow-root --no-browser
    environment:
      JUPYTER_TOKEN=abcdef1234567890abcd1234567890ab
""")
        
        scanner = RiskExtensionScanner(repo_root=tmpdir)
        findings = scanner.scan_compose_for_jupyterlab(compose_path)
        
        # Should detect root access and/or hardcoded token
        assert len(findings) >= 1, \
            f"Should detect JupyterLab risk, found: {findings}"
        
        finding = findings[0]
        assert finding.category == "jupyterlab_code_environment", \
            f"Category should be jupyterlab_code_environment: {finding.category}"
        assert finding.severity in [RiskLevel.HIGH, RiskLevel.MEDIUM], \
            f"Severity should be HIGH or MEDIUM: {finding.severity}"
        
        print("PASS: J24-3_detect_jupyterlab_root_access")


def test_requirements_scanning():
    """J24-4: Requirements.txt scanning catches unversioned dependencies.
    
    Verifies that packages without pinned versions (==) are flagged as LOW risk.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        # Create a requirements file with mixed versioning
        req_path = os.path.join(tmpdir, "requirements.txt")
        with open(req_path, "w") as f:
            f.write("""# Dependencies
fastapi==0.104.0
pydantic>=2.0
requests
some-unpinned-package
numpy==1.24.0
""")
        
        scanner = RiskExtensionScanner(repo_root=tmpdir)
        findings = scanner.scan_requirements_txt()
        
        # Should detect unversioned packages (requests, some-unpinned-package)
        assert len(findings) >= 1, \
            f"Should detect unversioned dependencies, found: {findings}"
        
        for finding in findings:
            assert finding.category == "unversioned_dependency", \
                f"Category should be unversioned_dependency: {finding.category}"
            assert finding.severity == RiskLevel.LOW
        
        print("PASS: J24-4_requirements_scanning")


def test_allowlist_compliance_report():
    """J24-5: Allowlist compliance report is accurate.
    
    Verifies that the allowlist_compliance dict in ScanReport correctly
    reports compliance status based on scan findings.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        scanner = RiskExtensionScanner(repo_root=tmpdir)
        
        # Create a risky compose file
        compose_path = os.path.join(tmpdir, "compose.test.yml")
        with open(compose_path, "w") as f:
            f.write("""services:
  openwebui:
    environment:
      OPENWEBUI_TOOL_EXECUTION_ENABLED="true"
""")
        
        report = scanner.scan_all(compose_files=[compose_path])
        
        compliance = report.allowlist_compliance
        assert "openwebui_tools_allowed" in compliance, \
            "Allowlist compliance should include openwebui check"
        assert "overall_compliance" in compliance
        
        # With high severity findings, overall compliance should be False
        has_high = any(f.severity == RiskLevel.HIGH for f in report.findings)
        if has_high:
            assert not compliance["overall_compliance"], \
                "Overall compliance should be False when HIGH findings exist"
        
        print("PASS: J24-5_allowlist_compliance_report")


def test_clean_scan_produces_valid_empty_report():
    """J24-6: Clean scan (no risks) produces valid empty report.
    
    Verifies that a clean repository with no risky patterns produces
    a valid ScanReport with 0 findings and allowlist_pass=True.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        # Create a safe compose file (no risky patterns)
        compose_path = os.path.join(tmpdir, "compose.safe.yml")
        with open(compose_path, "w") as f:
            f.write("""services:
  ollama:
    image: ollama/ollama:latest
    volumes:
      - /srv/agentic/ollama/models:/root/.ollama
""")
        
        scanner = RiskExtensionScanner(repo_root=tmpdir)
        report = scanner.scan_all(compose_files=[compose_path])
        
        # Verify summary is valid
        summary = report.summary()
        assert summary["findings_total"] == 0, \
            f"Clean scan should have 0 findings: {summary['findings_total']}"
        assert summary["allowlist_pass"] is True, \
            "Clean scan should pass allowlist check"
        
        # Verify no findings
        assert len(report.findings) == 0, \
            f"No findings expected, got: {report.findings}"
        
        print("PASS: J24-6_clean_scan_produces_valid_empty_report")


if __name__ == "__main__":
    test_detect_op_webui_python_execution()
    test_detect_comfyui_custom_node_install()
    test_detect_jupyterlab_root_access()
    test_requirements_scanning()
    test_allowlist_compliance_report()
    test_clean_scan_produces_valid_empty_report()
    print("\n=== J24_risk_extension_scanner passed ===")
