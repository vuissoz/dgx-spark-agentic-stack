#!/usr/bin/env python3
import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

REQUIRED_HEADING_GROUPS = [
    ["## Executive Summary", "## Research Questions"],
    ["## Method"],
    ["## Findings"],
    ["## Conflicts / Unverified"],
    ["## Recommendations"],
    ["## Source Notes"],
    ["## Bibliography"],
]

SOURCE_REQUIRED_FIELDS = [
    "url",
    "title",
    "domain",
    "source_type",
    "freshness",
    "relevance",
    "fetched",
    "fulltext_status",
    "duplicate_cluster",
    "query_family",
]

CLAIM_REQUIRED_FIELDS = [
    "claim",
    "supporting_sources",
    "contradicting_sources",
    "confidence",
    "verdict",
    "impact",
]

COVERAGE_REQUIRED_FIELDS = [
    "coverage_score",
    "publication_ready",
    "covered_questions",
    "open_questions",
    "gaps",
    "quality_notes",
    "evidence_gaps",
    "encoding_hygiene_issues",
]

MOJIBAKE_MARKERS = ("\u0420", "\u0421\u0453", "\u0421\u201a", "\u0432\u2030", "\u0432\u045a")
WEAK_SOURCE_MARKERS = ("linkedin.com", "reddit.com", "medium.com", "substack.com", "dev.to", "blog.")
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


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def normalize_url(url: str) -> str:
    parsed = urlparse((url or "").strip())
    path_part = (parsed.path or "").rstrip("/")
    return f"{parsed.scheme}://{parsed.netloc}{path_part}" if parsed.scheme and parsed.netloc else (url or "").strip().rstrip("/")


def domain_of(url: str) -> str:
    return urlparse(url).netloc.lower()


def is_web_url(url: str) -> bool:
    parsed = urlparse((url or "").strip())
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def ensure_list(value):
    return value if isinstance(value, list) else []


def extract_year_candidates(text: str):
    return {int(match) for match in re.findall(r"\b(20\d{2})\b", text or "")}


def file_mtime(path: Path):
    return datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc) if path.exists() else None


def get_queries(query_log):
    if isinstance(query_log, dict):
        return ensure_list(query_log.get("queries"))
    if isinstance(query_log, list):
        return query_log
    return []


def has_mojibake(value):
    if isinstance(value, dict):
        return any(has_mojibake(item) for item in value.values())
    if isinstance(value, list):
        return any(has_mojibake(item) for item in value)
    if isinstance(value, str):
        return any(marker in value for marker in MOJIBAKE_MARKERS)
    return False


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


def is_wide_topic(plan: dict) -> bool:
    topic = str((plan or {}).get("topic", "")).lower()
    if not topic:
        return False
    markers = ("best", "top", "landscape", "compare", "comparison", "deep research", "open source", "llm")
    return any(marker in topic for marker in markers)


def is_weak_source(source: dict) -> bool:
    domain = str(source.get("domain") or "").lower()
    if source.get("source_type") != "tertiary":
        return False
    return any(marker in domain for marker in WEAK_SOURCE_MARKERS)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Deep Research artifacts and report")
    parser.add_argument("--report", required=True, help="Absolute or relative path to markdown report")
    parser.add_argument("--workspace", default=".", help="Workspace root")
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    report_path = Path(args.report)
    if not report_path.is_absolute():
        report_path = (workspace / report_path).resolve()

    tmp_dir = workspace / "tmp"
    required_files = {
        "research_plan": tmp_dir / "research_plan.json",
        "query_log": tmp_dir / "query_log.json",
        "source_registry": tmp_dir / "source_registry.json",
        "claim_ledger": tmp_dir / "claim_ledger.json",
        "coverage_report": tmp_dir / "coverage_report.json",
    }

    issues = []
    artifacts = {}
    artifact_mtimes = {}
    artifact_data = {}
    for key, path in required_files.items():
        artifacts[key] = str(path)
        if not path.exists():
            issues.append(f"Missing artifact: {path.name}")
            continue
        artifact_mtimes[key] = file_mtime(path)
        artifact_data[key] = load_json(path)

    if not report_path.exists():
        issues.append(f"Missing report: {report_path}")
        print(json.dumps({"status": "FAIL", "issues": issues}, ensure_ascii=False, indent=2))
        return 1

    report_mtime = file_mtime(report_path)
    report_text = report_path.read_text(encoding="utf-8")
    for variants in REQUIRED_HEADING_GROUPS:
        if not any(heading in report_text for heading in variants):
            issues.append(f"Missing heading group: {' | '.join(variants)}")

    inline_links = re.findall(r"\[[^\]]+\]\((https?://[^)]+)\)", report_text)
    normalized_report_urls = {normalize_url(url) for url in inline_links}
    bibliography_section = section_text(report_text, "## Bibliography")
    bibliography_lines = re.findall(r"^\d+\.\s+.+https?://\S+.*$", bibliography_section, flags=re.MULTILINE)
    bibliography_urls = re.findall(r"(https?://[^\s)]+)", bibliography_section)
    legacy_citations = re.findall(r"\[source:\d+(?:\s*,\s*\d+)*\]", report_text)
    if not inline_links:
        issues.append("Report has no inline markdown links")
    if not bibliography_lines:
        issues.append("Report has no numbered bibliography entries")
    if legacy_citations:
        issues.append("Report still uses legacy [source:N] citations")
    if bibliography_section and (contains_local_reference(bibliography_section) or any(not is_web_url(url) for url in bibliography_urls)):
        issues.append("Bibliography contains local paths or pseudo-URLs instead of external web sources")

    source_count = 0
    verified_claim_count = 0
    coverage_score = 0.0
    open_questions = []
    conflicts = []

    source_registry = artifact_data.get("source_registry", {"sources": []})
    claim_ledger = artifact_data.get("claim_ledger", {"claims": []})
    coverage_report = artifact_data.get("coverage_report", {"open_questions": [], "conflicts": [], "coverage_score": 0.0})

    task_date = None
    research_plan_mtime = artifact_mtimes.get("research_plan")
    research_plan = artifact_data.get("research_plan")
    if research_plan:
        task_date = str(research_plan.get("task_date") or "").strip() or None

    if research_plan and has_mojibake(research_plan):
        issues.append("research_plan.json contains mojibake")

    query_log = artifact_data.get("query_log", {"queries": []})
    if has_mojibake(query_log):
        issues.append("query_log.json contains mojibake")
    if has_mojibake(source_registry):
        issues.append("source_registry.json contains mojibake")
    if has_mojibake(claim_ledger):
        issues.append("claim_ledger.json contains mojibake")
    if has_mojibake(coverage_report):
        issues.append("coverage_report.json contains mojibake")

    queries = get_queries(query_log)
    if not queries:
        issues.append("query_log.json has no query entries")

    sources = ensure_list(source_registry.get("sources"))
    source_count = len(sources)
    if source_count == 0:
        issues.append("source_registry.json has no sources")

    source_urls = set()
    fetched_source_urls = set()
    unique_domains = set()
    for source in sources:
        if not isinstance(source, dict):
            issues.append("source_registry.json contains a non-object source entry")
            continue
        for field in SOURCE_REQUIRED_FIELDS:
            if field not in source:
                issues.append(f"source_registry.json source missing field: {field}")
        url = str(source.get("url") or "").strip()
        if not is_web_url(url):
            issues.append(f"source_registry.json contains non-web URL: {url or '<empty>'}")
            continue
        normalized = normalize_url(url)
        source_urls.add(normalized)
        unique_domains.add(domain_of(url))
        if source.get("fetched"):
            fetched_source_urls.add(normalized)
        if contains_local_reference(str(source.get("title") or "")):
            issues.append(f"Source title leaks local artifact reference: {url}")
        if source.get("fetched") and str(source.get("fulltext_status") or "").lower() == "not_fetched":
            issues.append(f"Fetched source is marked not_fetched: {url}")

    claims = ensure_list(claim_ledger.get("claims"))
    if not claims:
        issues.append("claim_ledger.json has no claims")
    for claim in claims:
        if not isinstance(claim, dict):
            issues.append("claim_ledger.json contains a non-object claim entry")
            continue
        for field in CLAIM_REQUIRED_FIELDS:
            if field not in claim:
                issues.append(f"claim_ledger.json claim missing field: {field}")
        if claim.get("verdict") == "verified":
            verified_claim_count += 1
        for url in ensure_list(claim.get("supporting_sources")) + ensure_list(claim.get("contradicting_sources")):
            if contains_local_reference(str(url)):
                issues.append("Claims must not cite local artifacts as evidence")
            if str(claim.get("verdict")) == "verified" and normalize_url(str(url)) not in fetched_source_urls:
                issues.append("Verified claim cites a source that is not marked fetched")

    if verified_claim_count == 0:
        issues.append("No verified claims found")

    if not isinstance(coverage_report, dict):
        issues.append("coverage_report.json is not an object")
        coverage_report = {}
    else:
        for field in COVERAGE_REQUIRED_FIELDS:
            if field not in coverage_report:
                issues.append(f"coverage_report.json missing field: {field}")
        coverage_score = float(coverage_report.get("coverage_score") or 0.0)
        open_questions = ensure_list(coverage_report.get("open_questions"))
        conflicts = ensure_list(coverage_report.get("conflicts"))

    if task_date and task_date not in report_text:
        issues.append(f"Report must mention the task date {task_date}")
    if contains_local_reference(report_text):
        issues.append("Report contains local artifact references")

    findings_section = section_text(report_text, "## Findings")
    finding_links = re.findall(r"\[[^\]]+\]\((https?://[^)]+)\)", findings_section)
    if not finding_links:
        issues.append("## Findings must contain inline markdown links")
    for url in finding_links:
        if normalize_url(url) not in source_urls:
            issues.append("Report findings link is not traceable to source_registry.json")
            break

    if any(is_weak_source(source) for source in sources if isinstance(source, dict)) and verified_claim_count < 2:
        issues.append("Weak-source-heavy run lacks enough verified claims")

    if is_wide_topic(research_plan or {}) and source_count < 8:
        issues.append("Broad deep research run has fewer than 8 sources")
    if is_wide_topic(research_plan or {}) and len(unique_domains) < 3:
        issues.append("Broad deep research run has fewer than 3 unique domains")

    stale_artifacts = []
    for key, mtime in artifact_mtimes.items():
        if not mtime or not report_mtime or mtime > report_mtime and key != "coverage_report":
            continue
        if report_mtime and mtime and (report_mtime - mtime).total_seconds() > 86400:
            stale_artifacts.append(key)
    if stale_artifacts and report_mtime and research_plan_mtime and research_plan_mtime < report_mtime:
        issues.append(f"Artifacts look stale relative to report: {', '.join(sorted(stale_artifacts))}")

    summary = {
        "status": "PASS" if not issues else "FAIL",
        "report_path": str(report_path),
        "source_count": source_count,
        "verified_claim_count": verified_claim_count,
        "coverage_score": round(coverage_score, 3),
        "open_questions": open_questions,
        "conflicts": conflicts,
        "artifacts": artifacts,
        "issues": issues,
        "report_years": sorted(extract_year_candidates(report_text)),
        "source_domains": sorted(unique_domains),
        "traceable_report_links": len(normalized_report_urls & source_urls),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if not issues else 1


if __name__ == "__main__":
    raise SystemExit(main())
