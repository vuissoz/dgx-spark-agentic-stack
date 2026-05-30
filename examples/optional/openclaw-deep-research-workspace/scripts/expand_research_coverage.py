#!/usr/bin/env python3
"""Expand discovery breadth and normalize coverage against core research questions."""

import argparse
import ast
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
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


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def ensure_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def normalize_url(url: str) -> str:
    parsed = urlparse((url or "").strip())
    path_part = (parsed.path or "").rstrip("/")
    return f"{parsed.scheme}://{parsed.netloc}{path_part}" if parsed.scheme and parsed.netloc else (url or "").strip().rstrip("/")


def domain_of(url: str) -> str:
    return urlparse(url).netloc.lower()


def contains_local_reference(text: str) -> bool:
    lowered = (text or "").lower()
    return any(marker in lowered for marker in LOCAL_REFERENCE_MARKERS)


def is_web_url(url: str) -> bool:
    parsed = urlparse((url or "").strip())
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def classify_source_type(url: str) -> str:
    domain = domain_of(url)
    primary_markers = (".gov", ".edu", "github.com", "huggingface.co", "arxiv.org", "docs.")
    secondary_markers = ("wikipedia.org", "medium.com", "substack.com", "blog.")
    if any(marker in domain for marker in primary_markers):
        return "primary"
    if any(marker in domain for marker in secondary_markers):
        return "secondary"
    return "tertiary"


def query_result_urls(entry: dict[str, Any]) -> list[str]:
    urls = []
    for field in ("result_urls", "sources_found", "top_urls"):
        for value in ensure_list(entry.get(field)):
            if isinstance(value, str) and value.strip():
                urls.append(value.strip())
    seen = set()
    normalized = []
    for url in urls:
        norm = normalize_url(url)
        if norm in seen:
            continue
        seen.add(norm)
        normalized.append(url)
    return normalized


def normalize_text_tokens(text: str) -> list[str]:
    return [token for token in re.findall(r"[\w-]+", (text or "").lower(), flags=re.UNICODE) if len(token) >= 4]


def token_overlap_score(left: str, right: str) -> int:
    left_tokens = set(normalize_text_tokens(left))
    right_tokens = set(normalize_text_tokens(right))
    return len(left_tokens & right_tokens)


def question_is_covered(question: str, covered_questions: list[str]) -> bool:
    return any(token_overlap_score(question, item) >= 3 for item in covered_questions)


def question_is_open(question: str, open_questions: list[str]) -> bool:
    return any(token_overlap_score(question, item) >= 3 for item in open_questions)


def claim_supports_anchor(anchor: str, claims: list[dict[str, Any]]) -> bool:
    if not anchor:
        return False
    return any(token_overlap_score(anchor, str(claim.get("claim", ""))) >= 2 for claim in claims)


def claim_has_traceable_external_source(claim: dict[str, Any]) -> bool:
    sources = ensure_list(claim.get("supporting_sources"))
    return any(is_web_url(str(source)) and not contains_local_reference(str(source)) for source in sources)


def question_has_substantive_partial_coverage(
    question: str,
    anchor: str,
    matched_claims: list[dict[str, Any]],
    covered_questions: list[str],
) -> bool:
    if not matched_claims:
        return False
    if not any(str(claim.get("verdict")) == "partially_verified" for claim in matched_claims):
        return False
    if not any(claim_has_traceable_external_source(claim) for claim in matched_claims):
        return False
    if any(token_overlap_score(question, str(claim.get("claim", ""))) >= 3 for claim in matched_claims):
        return True
    return question_is_covered(question, covered_questions) or claim_supports_anchor(anchor or question, matched_claims)


def coerce_question_text(item: Any) -> str:
    if isinstance(item, dict):
        return str(item.get("question") or item.get("text") or "").strip()
    if isinstance(item, str):
        stripped = item.strip()
        if stripped.startswith("{") and stripped.endswith("}"):
            try:
                parsed = ast.literal_eval(stripped)
                if isinstance(parsed, dict):
                    return str(parsed.get("question") or parsed.get("text") or stripped).strip()
            except Exception:
                return stripped
        return stripped
    return str(item or "").strip()


def coerce_question_id(item: Any) -> str:
    if isinstance(item, dict):
        return str(item.get("id") or "").strip()
    return ""


def claims_for_question(question_id: str, question_text: str, claims: list[dict[str, Any]]) -> list[dict[str, Any]]:
    matched = []
    for claim in claims:
        claim_qid = str(claim.get("question_id") or "").strip()
        if question_id and claim_qid == question_id:
            matched.append(claim)
            continue
        if question_text and token_overlap_score(question_text, str(claim.get("claim", ""))) >= 3:
            matched.append(claim)
    return matched


def claims_for_anchor(anchor: str, claims: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not anchor:
        return []
    return [claim for claim in claims if token_overlap_score(anchor, str(claim.get("claim", ""))) >= 2]


def build_query_pair(question: str, anchor: str) -> list[dict[str, Any]]:
    lowered = f"{question} {anchor}".lower()
    if any(marker in lowered for marker in ("license", "mit", "apache", "llama")):
        return [
            {"query": f"{anchor or question} official license model card", "query_family": "source-seeking", "include_domains": ["huggingface.co", "github.com"]},
            {"query": f"{anchor or question} contradiction commercial use restrictions", "query_family": "contradiction", "include_domains": ["github.com", "huggingface.co"]},
        ]
    if any(marker in lowered for marker in ("vram", "quant", "deployment", "gpu")):
        return [
            {"query": f"{anchor or question} quantization requirements official docs", "query_family": "source-seeking", "include_domains": ["github.com", "huggingface.co"]},
            {"query": f"{anchor or question} benchmark spec inference memory", "query_family": "benchmark-spec", "include_domains": ["github.com", "arxiv.org"]},
        ]
    if any(marker in lowered for marker in ("context", "128k", "200k")):
        return [
            {"query": f"{anchor or question} official context window model card", "query_family": "source-seeking", "include_domains": ["huggingface.co", "github.com"]},
            {"query": f"{anchor or question} benchmark spec long context", "query_family": "benchmark-spec", "include_domains": ["arxiv.org", "huggingface.co"]},
        ]
    if any(marker in lowered for marker in ("integrat", "tool", "framework", "langchain", "autogen", "crewai")):
        return [
            {"query": f"{anchor or question} official integration docs github", "query_family": "source-seeking", "include_domains": ["github.com"]},
            {"query": f"{anchor or question} contradiction framework example", "query_family": "contradiction", "include_domains": ["github.com"]},
        ]
    return [
        {"query": f"{anchor or question} official model card benchmarks", "query_family": "source-seeking", "include_domains": ["huggingface.co", "github.com", "arxiv.org"]},
        {"query": f"{anchor or question} benchmark spec 2026", "query_family": "benchmark-spec", "include_domains": ["huggingface.co", "arxiv.org"]},
    ]


def materialize_discovery(query_log: dict[str, Any], source_registry: dict[str, Any]) -> int:
    sources = ensure_list(source_registry.get("sources"))
    existing_urls = {normalize_url(item.get("url", "")) for item in sources if item.get("url")}
    domain_counts: dict[str, int] = {}
    for item in sources:
        domain = domain_of(item.get("url", ""))
        if domain:
            domain_counts[domain] = domain_counts.get(domain, 0) + 1

    added = 0
    for entry in ensure_list(query_log.get("queries")):
        query_family = str(entry.get("query_family") or "baseline")
        provider = str(entry.get("provider") or "unknown")
        per_query_added = 0
        for rank, raw_url in enumerate(query_result_urls(entry), start=1):
            normalized = normalize_url(raw_url)
            if not normalized or normalized in existing_urls or not is_web_url(raw_url):
                continue
            domain = domain_of(raw_url)
            if domain and domain_counts.get(domain, 0) >= 3:
                continue
            sources.append(
                {
                    "url": raw_url,
                    "title": raw_url,
                    "domain": domain,
                    "source_type": classify_source_type(raw_url),
                    "freshness": "unknown",
                    "relevance": "discovery",
                    "fetched": False,
                    "fulltext_status": "not_fetched",
                    "duplicate_cluster": normalized,
                    "query_family": query_family,
                    "provider": provider,
                    "discovery_only": True,
                    "discovery_rank": rank,
                }
            )
            existing_urls.add(normalized)
            if domain:
                domain_counts[domain] = domain_counts.get(domain, 0) + 1
            added += 1
            per_query_added += 1
            if per_query_added >= 2:
                break
    source_registry["sources"] = sources
    return added


def summarize_claims(claims: list[dict[str, Any]]) -> dict[str, int]:
    counts = {"verified": 0, "partially_verified": 0, "unverified": 0, "conflicted": 0}
    for claim in claims:
        verdict = str(claim.get("verdict") or "").strip()
        if verdict in counts:
            counts[verdict] += 1
    return counts


def unique_domains(sources: list[dict[str, Any]]) -> list[str]:
    domains = {domain_of(item.get("url", "")) for item in sources if item.get("url")}
    return sorted(domain for domain in domains if domain)


def compute_coverage_report(workspace: Path) -> dict[str, Any]:
    tmp_dir = workspace / "tmp"
    research_plan = load_json(tmp_dir / "research_plan.json", {})
    query_log = load_json(tmp_dir / "query_log.json", {"queries": []})
    source_registry = load_json(tmp_dir / "source_registry.json", {"sources": []})
    claim_ledger = load_json(tmp_dir / "claim_ledger.json", {"claims": []})
    coverage_report = load_json(tmp_dir / "coverage_report.json", {})

    materialize_discovery(query_log, source_registry)

    sources = ensure_list(source_registry.get("sources"))
    claims = ensure_list(claim_ledger.get("claims"))
    source_count = len([item for item in sources if item.get("url")])
    domains = unique_domains(sources)
    covered_questions = ensure_list(coverage_report.get("covered_questions"))
    open_questions = ensure_list(coverage_report.get("open_questions"))
    claim_counts = summarize_claims(claims)

    questions = ensure_list(research_plan.get("questions"))
    unresolved = []
    suggested_queries = []

    for raw_item in questions:
        question_text = coerce_question_text(raw_item)
        if not question_text:
            continue
        question_id = coerce_question_id(raw_item)
        matched_claims = claims_for_question(question_id, question_text, claims)
        anchor = ""
        if isinstance(raw_item, dict):
            anchor = str(raw_item.get("anchor") or "").strip()
        if not matched_claims and anchor:
            matched_claims = claims_for_anchor(anchor, claims)
        if question_is_covered(question_text, covered_questions):
            continue
        if question_has_substantive_partial_coverage(question_text, anchor, matched_claims, covered_questions):
            continue
        if question_is_open(question_text, open_questions):
            unresolved.append(question_text)
            suggested_queries.extend(build_query_pair(question_text, anchor))
            continue
        unresolved.append(question_text)
        suggested_queries.extend(build_query_pair(question_text, anchor))

    needed = bool(unresolved) or source_count < 6 or len(domains) < 3
    coverage_score = 0.0
    if questions:
        answered = max(0, len(questions) - len(unresolved))
        coverage_score = answered / max(1, len(questions))
    elif source_count:
        coverage_score = min(1.0, source_count / 6)

    quality_notes = ensure_list(coverage_report.get("quality_notes"))
    evidence_gaps = ensure_list(coverage_report.get("evidence_gaps"))
    gaps = ensure_list(coverage_report.get("gaps"))

    if source_count < 4:
        quality_notes.append("Low source breadth: fewer than 4 unique sources are registered.")
    if len(domains) < 2:
        quality_notes.append("Low domain diversity: fewer than 2 unique domains are registered.")
    if claim_counts["verified"] == 0 and claim_counts["partially_verified"] == 0:
        evidence_gaps.append("No claims are verified or partially verified yet.")
    if unresolved:
        gaps.extend(unresolved)

    deduped_queries = []
    seen_queries = set()
    for item in suggested_queries:
        key = (item["query"], item["query_family"], tuple(item.get("include_domains", [])))
        if key in seen_queries:
            continue
        seen_queries.add(key)
        deduped_queries.append(item)

    result = {
        "ts": iso_now(),
        "coverage_score": round(coverage_score, 3),
        "needed": needed,
        "covered_questions": sorted(dict.fromkeys(coerce_question_text(item) for item in covered_questions if coerce_question_text(item))),
        "open_questions": sorted(dict.fromkeys(unresolved or [coerce_question_text(item) for item in open_questions if coerce_question_text(item)])),
        "gaps": sorted(dict.fromkeys(item for item in gaps if item)),
        "quality_notes": sorted(dict.fromkeys(item for item in quality_notes if item)),
        "evidence_gaps": sorted(dict.fromkeys(item for item in evidence_gaps if item)),
        "encoding_hygiene_issues": ensure_list(coverage_report.get("encoding_hygiene_issues")),
        "source_count": source_count,
        "unique_domains": domains,
        "claim_counts": claim_counts,
        "suggested_queries": deduped_queries,
    }
    save_json(tmp_dir / "source_registry.json", source_registry)
    save_json(tmp_dir / "coverage_report.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Expand Deep Research coverage with follow-up guidance")
    parser.add_argument("--workspace", default=".", help="Workspace root")
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    summary = compute_coverage_report(workspace)
    print(json.dumps(summary, ensure_ascii=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
