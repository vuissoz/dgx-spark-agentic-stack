#!/usr/bin/env python3
"""src/agentic/implementations/risk_extension_scanner.py — §9.3 Extensions à risque governance scanner.

Scans compose files, Python dependencies, and custom nodes for:
- Python execution vectors (Tools/Functions/Pipelines that run arbitrary code)
- Unknown/unversioned external dependencies
- Custom nodes without version/digest/provenance tracking
- JupyterLab as full code environment (not just web page)

Produces allowlist compliance reports and risk assessments.

Conforms to PLAN.md §9.3:
- OpenWebUI Tools/Functions/Pipelines: creation/import disabled by default, allowlist + review
- ComfyUI custom nodes: versions/digests, provenance, allowlist, scan, test
- JupyterLab: treated as code environment with isolation/quota/external access controls
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
import time
from typing import Any, Optional


# ── Risk Levels ──────────────────────────────────────────────────────────

class RiskLevel:
    LOW = "low"
    MEDIUM = "medium"  
    HIGH = "high"
    CRITICAL = "critical"


# ── Data Classes ─────────────────────────────────────────────────────────

@dataclass
class ScanFinding:
    """A single security risk finding from scanning."""
    category: str           # e.g., "python_execution", "unknown_dependency", "unversioned_node"
    severity: str           # LOW, MEDIUM, HIGH, CRITICAL
    source: str             # File/component where found
    description: str        # Human-readable description
    recommendation: str     # Action to mitigate
    
    def to_dict(self) -> dict[str, Any]:
        return {
            "category": self.category,
            "severity": self.severity,
            "source": self.source,
            "description": self.description,
            "recommendation": self.recommendation,
        }


@dataclass
class ExtensionAllowlist:
    """Tracks allowed/disallowed extensions per component."""
    openwebui_tools: list[str] = field(default_factory=list)      # Allowed OpenWebUI Tool names
    openwebui_pipelines: list[str] = field(default_factory=list)  # Allowed Pipeline IDs
    comfyui_nodes: dict[str, str] = field(default_factory=dict)   # node_name -> "digest@sha256:..." or version
    jupyterlab_allowed_packages: list[str] = field(default_factory=list)  # pre-approved packages


@dataclass
class ScanReport:
    """Complete scan report for §9.3 Extensions à risque governance."""
    scan_timestamp: float = 0.0
    compose_files_scanned: list[str] = field(default_factory=list)
    findings: list[ScanFinding] = field(default_factory=list)
    allowlist_compliance: dict[str, Any] = field(default_factory=dict)
    
    def summary(self) -> dict[str, Any]:
        """Generate summary for reporting."""
        counts = {level: 0 for level in [RiskLevel.LOW, RiskLevel.MEDIUM, RiskLevel.HIGH, RiskLevel.CRITICAL]}
        for f in self.findings:
            counts[f.severity] = counts.get(f.severity, 0) + 1
        
        return {
            "findings_total": len(self.findings),
            "findings_by_severity": counts,
            "allowlist_pass": all(f.severity not in [RiskLevel.HIGH, RiskLevel.CRITICAL] for f in self.findings),
            "recommendations_count": len([f for f in self.findings if f.recommendation]),
        }


# ── Scanner Engine ───────────────────────────────────────────────────────

class RiskExtensionScanner:
    """Scans for risk extensions per PLAN.md §9.3.
    
    Performs static analysis of compose files, Python code, and configuration
    to identify:
    1. Python execution vectors (Tools/Functions/Pipelines)
    2. Unversioned/untracked external dependencies
    3. Custom nodes without provenance tracking
    4. JupyterLab full code environment exposure
    
    Does NOT require Docker/runtime — purely static analysis.
    """
    
    def __init__(self, repo_root: str = ".", 
                 allowlist: Optional[ExtensionAllowlist] = None):
        self.repo_root = Path(repo_root)
        self.allowlist = allowlist or ExtensionAllowlist()
        self._findings: list[ScanFinding] = []
    
    def scan_all(self, compose_files: Optional[list[str]] = None) -> ScanReport:
        """Run complete §9.3 risk extension scan."""
        report = ScanReport(scan_timestamp=time.time())
        
        # Discover compose files if not specified
        if not compose_files:
            compose_files = self._find_compose_files()
        
        report.compose_files_scanned = compose_files
        
        # Run all scanner passes
        for cf in compose_files:
            report.findings.extend(self.scan_compose_for_python_execution(cf))
            report.findings.extend(self.scan_compose_for_custom_nodes(cf))
            report.findings.extend(self.scan_compose_for_jupyterlab(cf))
        
        # Check Python dependencies
        report.findings.extend(self.scan_requirements_txt())
        
        # Generate allowlist compliance report
        report.allowlist_compliance = self._check_allowlist_compliance(compose_files, report.findings)
        
        self._findings = report.findings
        return report
    
    def scan_compose_for_python_execution(self, compose_file: str) -> list[ScanFinding]:
        """§9.3: Detect OpenWebUI Tools/Functions/Pipelines that execute Python.
        
        These are high-risk because they can run arbitrary Python code inside containers.
        Policy: creation/import disabled by default, require explicit allowlist + review.
        """
        findings = []
        
        try:
            with open(compose_file) as f:
                content = f.read()
            
            # Look for OpenWebUI environment variables that enable Tools/Functions/Pipelines
            risky_patterns = [
                (r'OPENWEBUI_TOOL.*=.*["\']true', "OpenWebUI Tool execution enabled in compose env"),
                (r'OPENWEBUI_FUNCTION.*=.*["\']true', "OpenWebUI Function execution enabled in compose env"),
                (r'OPENWEBUI_PIPELINE.*=.*["\']true', "OpenWebUI Pipeline execution enabled in compose env"),
                (r'PIPELINE_EXECUTION_ENABLED.*=.*["\']1', "Generic pipeline execution flag set to true"),
            ]
            
            for pattern, desc in risky_patterns:
                if re.search(pattern, content):
                    findings.append(ScanFinding(
                        category="python_execution",
                        severity=RiskLevel.HIGH,
                        source=os.path.basename(compose_file),
                        description=f"Detected {desc}",
                        recommendation="Disable by default. Explicit allowlist review required before enabling.",
                    ))
            
            # Look for volume mounts that expose code execution vectors
            if re.search(r'/tools|/functions|/pipelines', content) and re.search(r'volumes:', content, re.IGNORECASE):
                findings.append(ScanFinding(
                    category="python_execution",
                    severity=RiskLevel.MEDIUM,
                    source=os.path.basename(compose_file),
                    description="Volume mount exposes tools/functions/pipelines directory — potential code execution surface",
                    recommendation="Verify mounted paths are read-only or contain only allowlisted content.",
                ))
                
        except FileNotFoundError:
            pass
        
        return findings
    
    def scan_compose_for_custom_nodes(self, compose_file: str) -> list[ScanFinding]:
        """§9.3: Detect ComfyUI custom nodes without version/digest/provenance tracking.
        
        Custom nodes are third-party code that can execute arbitrary Python inside
        the ComfyUI container. Each must have pinned versions, digests, and provenance.
        """
        findings = []
        
        try:
            with open(compose_file) as f:
                content = f.read()
            
            # Look for node installation commands (pip install, git clone of custom nodes)
            node_install_patterns = [
                (r'pip.*install.*comfyui|custom.?node', "Unversioned ComfyUI custom node installation via pip"),
                (r'git.?clone.*comfyui-.*|custom.*node.*repo', "Custom node cloned from external repo without version pinning"),
            ]
            
            for pattern, desc in node_install_patterns:
                if re.search(pattern, content, re.IGNORECASE):
                    findings.append(ScanFinding(
                        category="unversioned_node",
                        severity=RiskLevel.HIGH,
                        source=os.path.basename(compose_file),
                        description=desc,
                        recommendation="Pin version/digest. Require provenance verification before deployment.",
                    ))
            
            # Check if custom nodes directory is mounted with write permissions
            if re.search(r'custom_nodes.*writable|custom_nodes.*rw', content, re.IGNORECASE):
                findings.append(ScanFinding(
                    category="unversioned_node",
                    severity=RiskLevel.MEDIUM,
                    source=os.path.basename(compose_file),
                    description="Custom nodes directory mounted with write access — can install unvetted nodes at runtime",
                    recommendation="Mount read-only. Node installation should happen via build step with provenance verification.",
                ))
                
        except FileNotFoundError:
            pass
        
        return findings
    
    def scan_compose_for_jupyterlab(self, compose_file: str) -> list[ScanFinding]:
        """§9.3: Detect JupyterLab instances exposed as full code environments.
        
        JupyterLab must be treated as a code execution environment with isolation,
        quotas, and explicit external access controls — not just a web page.
        """
        findings = []
        
        try:
            with open(compose_file) as f:
                content = f.read()
            
            # Look for JupyterLab config that enables full code execution without isolation
            risky_patterns = [
                (r'jupyter.*--allow-root', "JupyterLab running as root — no user isolation"),
                (r'jupyter.*--no-browser|HEADLESS', "Headless Jupyter without browser security boundaries"),
                (r'tools/authtoken|token=.*[a-f0-9]{16,}', "Hardcoded Jupyter auth token in compose env"),
            ]
            
            for pattern, desc in risky_patterns:
                if re.search(pattern, content, re.IGNORECASE):
                    findings.append(ScanFinding(
                        category="jupyterlab_code_environment",
                        severity=RiskLevel.HIGH,
                        source=os.path.basename(compose_file),
                        description=desc,
                        recommendation="Run as non-root user. Use auth proxy or token rotation. Enforce code isolation and quotas.",
                    ))
            
            # Check if JupyterLab has unrestricted filesystem/network access
            if re.search(r'jupyter', content, re.IGNORECASE) and not re.search(r'tools/isolation|sandbox|jail', content, re.IGNORECASE):
                findings.append(ScanFinding(
                    category="jupyterlab_code_environment",
                    severity=RiskLevel.MEDIUM,
                    source=os.path.basename(compose_file),
                    description="JupyterLab detected without explicit isolation/sandbox configuration",
                    recommendation="Add code isolation layer (e.g., nvidia-container-toolkit + seccomp profiles). Enforce quota on CPU/GPU/memory.",
                ))
                
        except FileNotFoundError:
            pass
        
        return findings
    
    def scan_requirements_txt(self) -> list[ScanFinding]:
        """Scan Python requirements files for unversioned or risky dependencies."""
        findings = []
        
        req_files = [
            self.repo_root / "requirements.txt",
            self.repo_root / "src/agentic/requirements.txt",
        ]
        
        for req_file in req_files:
            if not req_file.exists():
                continue
            
            try:
                with open(req_file) as f:
                    lines = f.readlines()
                
                for line in lines:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    
                    # Check for unversioned packages (no == pinned version)
                    if re.match(r'^[a-zA-Z]', line) and '==' not in line and '>=' not in line:
                        pkg_name = re.split(r'[>=<]', line)[0].strip()
                        findings.append(ScanFinding(
                            category="unversioned_dependency",
                            severity=RiskLevel.LOW,
                            source=str(req_file.relative_to(self.repo_root)),
                            description=f"Unversioned Python dependency: {pkg_name}",
                            recommendation="Pin to specific version (e.g., pkg==1.2.3) for reproducible builds.",
                        ))
            
            except (PermissionError, FileNotFoundError):
                pass
        
        return findings
    
    def _check_allowlist_compliance(self, compose_files: list[str], findings: list) -> dict[str, Any]:
        """Check scan findings against the allowlist."""
        openwebui_violations = [f for f in findings if f.category == "python_execution"]
        comfyui_violations = [f for f in findings if f.category == "unversioned_node"]
        jupyter_violations = [f for f in findings if f.category == "jupyterlab_code_environment"]
        
        return {
            "openwebui_tools_allowed": len(self.allowlist.openwebui_tools) > 0 or not openwebui_violations,
            "comfyui_nodes_tracked": all(
                node in self.allowlist.comfyui_nodes 
                for f in comfyui_violations 
                for node in [f.source]
            ),
            "jupyterlab_isolated": not any(f.severity == RiskLevel.HIGH for f in jupyter_violations),
            "overall_compliance": all(
                f.severity not in [RiskLevel.HIGH, RiskLevel.CRITICAL] 
                for f in findings
            ),
        }
    
    def _find_compose_files(self) -> list[str]:
        """Find compose files in the repository."""
        compose_dir = self.repo_root / "compose"
        if not compose_dir.exists():
            return []
        
        files = []
        for pattern in ["*.yml", "*.yaml"]:
            files.extend(str(p) for p in compose_dir.glob(pattern))
        
        # Also check root
        for pattern in ["docker-compose*.yml", "docker-compose*.yaml", "compose*.yml", "compose*.yaml"]:
            found = list(self.repo_root.glob(pattern))
            if found:
                files.extend(str(p) for p in found)
        
        return sorted(set(files))


# ── Integration with ApplicationAdapters (§9.3) ─────────────────────────

def scan_application_risks(repo_root: str = ".") -> ScanReport:
    """Convenience function to scan all application risk extensions."""
    scanner = RiskExtensionScanner(repo_root=repo_root)
    return scanner.scan_all()


if __name__ == "__main__":
    report = scan_application_risks()
    
    summary = report.summary()
    print(json.dumps({
        "scan_type": "extensions_à_risque_governance",
        **summary,
    }, indent=2))
    
    if report.findings:
        print(f"\nFindings ({len(report.findings)}):")
        for f in report.findings:
            print(f"  [{f.severity}] {f.category}: {f.description}")
            print(f"    Source: {f.source}")
            print(f"    Fix: {f.recommendation}\n")
