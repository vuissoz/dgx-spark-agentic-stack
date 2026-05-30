#!/usr/bin/env python3
"""Lint report publication quality before validator/finalizer."""

import argparse
import json
import re
from pathlib import Path
from urllib.parse import urlparse


LOCAL_REFERENCE_MARKERS = (
    "https://tmp/",
    "file://",
    "tmp/",
    "tavily_last.json",
    "query_log.json",
    "source_registry.json",
    "claim_ledger.json",
    "coverage_report.json",
    "research_plan.json",
)


def load_json(path: Path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def normalize_url(url: str) -> str:
    parsed = urlparse((url or "").strip())
    path_part = (parsed.path or "").rstrip("/")
    return f"{parsed.scheme}://{parsed.netloc}{path_part}" if parsed.scheme and parsed.netloc else (url or "").strip().rstrip("/")


def is_web_url(url: str) -> bool:
    parsed = urlparse((url or "").strip())
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def section_text(markdown: str, heading: str) -> str:
    pattern = re.compile(rf"^{re.escape(heading)}\s*$", re.MULTILINE)
    match = pattern.search(markdown)
    if not match:
        return ""
    start = match.end()
    next_heading = re.search(r"^##\s+.+$", markdown[start:], flags=re.MULTILINE)
    if not next_heading:
        return markdown[start:]
    return markdown[start:start + next_heading.start()]


def contains_local_reference(text: str) -> bool:
    lowered = (text or "").lower()
    return any(marker in lowered for marker in LOCAL_REFERENCE_MARKERS)


def domain_of(url: str) -> str:
    return urlparse(url).netloc.lower()


def main() -> int:
    parser = argparse.ArgumentParser(description="Lint publication quality of a deep research report")
    parser.add_argument("--report", required=True, help="Absolute or relative path to markdown report")
    parser.add_argument("--workspace", default=".", help="Workspace root")
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    report_path = Path(args.report)
    if not report_path.is_absolute():
        report_path = (workspace / report_path).resolve()

    issues = []
    if not report_path.exists():
        issues.append(f"Missing report: {report_path}")
        print(json.dumps({"status": "FAIL", "issues": issues}, ensure_ascii=False, indent=2))
        return 1

    report_text = report_path.read_text(encoding="utf-8")
    findings = section_text(report_text, "## Findings")
    bibliography = section_text(report_text, "## Bibliography")

    findings_links = re.findall(r"\[[^\]]+\]\((https?://[^)\s]+)\)", findings)
    bibliography_urls = re.findall(r"(https?://[^\s)]+)", bibliography)
    all_report_links = re.findall(r"\[[^\]]+\]\((https?://[^)\s]+)\)", report_text)

    if not findings.strip():
        issues.append("Report is missing the ## Findings body")
    if not findings_links:
        issues.append("## Findings has no inline markdown links")
    if contains_local_reference(findings):
        issues.append("## Findings references local artifacts instead of external sources")
    if not bibliography.strip():
        issues.append("Report is missing the ## Bibliography body")
    if not bibliography_urls:
        issues.append("## Bibliography has no external URLs")
    if contains_local_reference(bibliography):
        issues.append("## Bibliography contains local paths or pseudo-URLs")
    if any(not is_web_url(url) for url in bibliography_urls):
        issues.append("## Bibliography contains non-web URLs")

    source_registry = load_json(workspace / "tmp" / "source_registry.json", {"sources": []})
    registry_urls = {
        normalize_url(item.get("url", ""))
        for item in source_registry.get("sources", [])
        if isinstance(item, dict) and item.get("url")
    }
    findings_overlap = {normalize_url(url) for url in findings_links} & registry_urls
    findings_overlap_ratio = len(findings_overlap) / max(1, len({normalize_url(url) for url in findings_links}))
    if findings_links and not findings_overlap:
        issues.append("## Findings links do not trace back to source_registry.json")
    if len(findings_links) >= 2 and findings_overlap_ratio < 0.5:
        issues.append("Less than 50% of ## Findings links are traceable to source_registry.json")

    unique_domains = {domain_of(url) for url in set(all_report_links + bibliography_urls) if domain_of(url)}
    summary = {
        "status": "PASS" if not issues else "FAIL",
        "report_path": str(report_path),
        "findings_inline_link_count": len(findings_links),
        "bibliography_url_count": len(bibliography_urls),
        "traceable_findings_link_count": len(findings_overlap),
        "unique_domain_count": len(unique_domains),
        "issues": issues,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if not issues else 1


if __name__ == "__main__":
    raise SystemExit(main())
