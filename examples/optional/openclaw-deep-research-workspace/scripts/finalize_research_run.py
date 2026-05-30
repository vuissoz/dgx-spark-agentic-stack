#!/usr/bin/env python3
"""
Finalize a research run into the M2M JSON schema expected by the main agent.
This script refuses to mark a run as SUCCESS when the validator does not pass.
"""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse


sys.stdout.reconfigure(encoding="utf-8")


def load_json(path: Path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, payload) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def summarize_findings(claims):
    findings = []
    for claim in claims:
        if claim.get("verdict") in {"verified", "partially_verified"}:
            findings.append(claim.get("claim", ""))
        if len(findings) >= 5:
            break
    return [item for item in findings if item]


def normalize_artifacts(artifacts, workspace: Path):
    normalized = {}
    for key, value in (artifacts or {}).items():
        candidate = Path(value)
        if not candidate.is_absolute():
            candidate = (workspace / candidate).resolve()
        normalized[key] = str(candidate)
    return normalized


def missing_artifact_paths(artifacts):
    missing = []
    for key, value in artifacts.items():
        if not Path(value).exists():
            missing.append(key)
    return missing


def collect_unverified(claims):
    items = []
    for claim in claims:
        if claim.get("verdict") in {"unverified", "conflicted"}:
            items.append(claim.get("claim", ""))
    return [item for item in items if item]


def run_json_script(script_path: Path, *extra_args):
    proc = subprocess.run(
        [sys.executable, str(script_path), *extra_args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    try:
        payload = json.loads(proc.stdout or "")
    except json.JSONDecodeError:
        payload = {
            "status": "FAIL",
            "issues": [proc.stderr.strip() or f"{script_path.name} returned non-JSON output"],
        }
    return proc, payload


def is_wide_topic(topic: str) -> bool:
    lowered = str(topic or "").lower()
    markers = ("best", "top", "landscape", "compare", "comparison", "deep research", "open source", "llm")
    return any(marker in lowered for marker in markers)


def domain_of(url: str) -> str:
    return urlparse(url).netloc.lower()


def slugify_topic(value: str) -> str:
    cleaned = "".join(ch.lower() if ch.isalnum() else "-" for ch in str(value or "research-report"))
    while "--" in cleaned:
        cleaned = cleaned.replace("--", "-")
    return cleaned.strip("-") or "research-report"


def canonicalize_report_path(report_path: Path, workspace: Path, research_plan: dict) -> Path:
    report_target = str((research_plan or {}).get("report_target") or "").strip()
    if report_target:
        canonical_path = Path(report_target)
        if not canonical_path.is_absolute():
            canonical_path = (workspace / report_target).resolve()
    else:
        task_date = str((research_plan or {}).get("task_date") or "").strip()
        topic = str((research_plan or {}).get("topic") or "").strip()
        if not task_date or not topic or not report_path.exists():
            return report_path
        report_dir = workspace / "reports"
        canonical_path = report_dir / f"{slugify_topic(topic)}_{task_date}.md"
    if not report_path.exists():
        return canonical_path if canonical_path.exists() else report_path
    if canonical_path.resolve() == report_path.resolve():
        return report_path
    canonical_path.write_text(report_path.read_text(encoding="utf-8"), encoding="utf-8")
    sibling_pdf = report_path.with_suffix(".pdf")
    canonical_pdf = canonical_path.with_suffix(".pdf")
    if sibling_pdf.exists():
        shutil.copyfile(sibling_pdf, canonical_pdf)
    return canonical_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Finalize Deep Research output into M2M JSON")
    parser.add_argument("--report", required=True, help="Absolute or relative path to the markdown report")
    parser.add_argument("--workspace", default=".", help="Workspace root")
    parser.add_argument("--task-summary", default="Deep research completed with validated artifacts.", help="Short one-line summary for the main agent")
    parser.add_argument("--confidence", type=float, default=0.8, help="Confidence score to include in the final payload")
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    report_path = Path(args.report)
    if not report_path.is_absolute():
        report_path = (workspace / report_path).resolve()

    coverage_expander = workspace / "scripts" / "expand_research_coverage.py"
    subprocess.run(
        [sys.executable, str(coverage_expander), "--workspace", str(workspace)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    normalizer = workspace / "scripts" / "normalize_research_artifacts.py"
    subprocess.run(
        [sys.executable, str(normalizer), "--workspace", str(workspace)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    report_linter = workspace / "scripts" / "report_lint.py"
    _, lint = run_json_script(report_linter, "--report", str(report_path), "--workspace", str(workspace))

    validator = workspace / "scripts" / "validate_research_report.py"
    _, validation = run_json_script(validator, "--report", str(report_path), "--workspace", str(workspace))
    if "report_path" not in validation:
        validation.update({
            "report_path": str(report_path),
            "source_count": 0,
            "verified_claim_count": 0,
            "coverage_score": 0.0,
            "open_questions": [],
            "conflicts": [],
            "artifacts": {},
        })

    tmp_dir = workspace / "tmp"
    research_plan = load_json(tmp_dir / "research_plan.json", {})
    report_path = canonicalize_report_path(report_path, workspace, research_plan if isinstance(research_plan, dict) else {})
    source_registry = load_json(tmp_dir / "source_registry.json", {"sources": []})
    claim_ledger = load_json(tmp_dir / "claim_ledger.json", {"claims": []})
    coverage_report = load_json(tmp_dir / "coverage_report.json", {})

    sources = [item.get("url") for item in source_registry.get("sources", [])] if isinstance(source_registry, dict) else []
    unique_sources = sorted(dict.fromkeys([item for item in sources if item]))
    unique_domains = sorted({domain_of(item) for item in unique_sources if domain_of(item)})
    claims = claim_ledger.get("claims", []) if isinstance(claim_ledger, dict) else []
    verified_claim_count = sum(1 for claim in claims if claim.get("verdict") == "verified")
    key_findings = summarize_findings(claims)
    unverified_claims = collect_unverified(claims)

    artifacts = normalize_artifacts(validation.get("artifacts", {
        "research_plan": str(tmp_dir / "research_plan.json"),
        "query_log": str(tmp_dir / "query_log.json"),
        "source_registry": str(tmp_dir / "source_registry.json"),
        "claim_ledger": str(tmp_dir / "claim_ledger.json"),
        "coverage_report": str(tmp_dir / "coverage_report.json"),
    }), workspace)
    missing_artifacts = missing_artifact_paths(artifacts)

    wide_topic = is_wide_topic(research_plan.get("topic", "") if isinstance(research_plan, dict) else "")
    publication_threshold_issues = []
    if wide_topic and len(unique_sources) < 8:
        publication_threshold_issues.append("Publication threshold not met: source_count < 8 for a broad deep-research run")
    if wide_topic and len(unique_domains) < 3:
        publication_threshold_issues.append("Publication threshold not met: < 3 unique domains for a broad deep-research run")

    publication_ready = lint.get("status") == "PASS" and validation.get("status") == "PASS" and not publication_threshold_issues
    if isinstance(coverage_report, dict):
        coverage_report["publication_ready"] = publication_ready
        save_json(tmp_dir / "coverage_report.json", coverage_report)

    status = "SUCCESS" if publication_ready else "PARTIAL"
    if not report_path.exists():
        status = "FAILURE"
    if missing_artifacts:
        status = "PARTIAL" if status == "SUCCESS" else status

    payload = {
        "status": status,
        "task_summary": args.task_summary,
        "report_path": str(report_path),
        "confidence_score": args.confidence if status == "SUCCESS" else max(0.3, min(args.confidence, 0.65)),
        "key_findings": key_findings,
        "unverified_claims": unverified_claims,
        "open_questions": validation.get("open_questions", []),
        "conflicts": validation.get("conflicts", []),
        "source_count": validation.get("source_count", len(unique_sources)),
        "verified_claim_count": validation.get("verified_claim_count", verified_claim_count),
        "coverage_score": validation.get("coverage_score", 0.0),
        "artifacts": artifacts,
        "report_lint": lint,
        "validation": validation,
        "publication_threshold_issues": publication_threshold_issues,
    }

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if status == "SUCCESS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
