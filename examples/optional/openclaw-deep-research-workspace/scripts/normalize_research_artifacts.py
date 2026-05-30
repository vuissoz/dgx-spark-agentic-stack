#!/usr/bin/env python3
"""Normalize Deep Research artifacts into a validator-friendly shape."""

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json(path: Path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def ensure_list(value):
    return value if isinstance(value, list) else []


def normalize_url(url: str) -> str:
    parsed = urlparse((url or "").strip())
    path_part = (parsed.path or "").rstrip("/")
    return f"{parsed.scheme}://{parsed.netloc}{path_part}" if parsed.scheme and parsed.netloc else (url or "").strip().rstrip("/")


def domain_of(url: str) -> str:
    return urlparse(url).netloc.lower()


def normalize_source_registry(workspace: Path) -> dict:
    path = workspace / "tmp" / "source_registry.json"
    payload = load_json(path, {"sources": []})
    sources = []
    seen = set()
    for item in ensure_list(payload.get("sources")):
        if not isinstance(item, dict):
            continue
        url = str(item.get("url") or "").strip()
        normalized = normalize_url(url)
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        source = dict(item)
        source["url"] = url
        source["title"] = str(source.get("title") or url)
        source["domain"] = str(source.get("domain") or domain_of(url))
        source["source_type"] = str(source.get("source_type") or "tertiary")
        source["freshness"] = str(source.get("freshness") or "unknown")
        source["relevance"] = str(source.get("relevance") or "unknown")
        source["fetched"] = bool(source.get("fetched"))
        source["fulltext_status"] = str(source.get("fulltext_status") or ("fetched" if source["fetched"] else "not_fetched"))
        source["duplicate_cluster"] = str(source.get("duplicate_cluster") or normalized)
        source["query_family"] = str(source.get("query_family") or "baseline")
        sources.append(source)
    payload["sources"] = sources
    payload["normalized_at"] = iso_now()
    save_json(path, payload)
    return payload


def normalize_claim_ledger(workspace: Path) -> dict:
    path = workspace / "tmp" / "claim_ledger.json"
    payload = load_json(path, {"claims": []})
    claims = []
    for item in ensure_list(payload.get("claims")):
        if not isinstance(item, dict):
            continue
        claim = dict(item)
        claim["claim"] = str(claim.get("claim") or "").strip()
        claim["supporting_sources"] = [str(value) for value in ensure_list(claim.get("supporting_sources")) if str(value).strip()]
        claim["contradicting_sources"] = [str(value) for value in ensure_list(claim.get("contradicting_sources")) if str(value).strip()]
        try:
            claim["confidence"] = float(claim.get("confidence", 0.0))
        except (TypeError, ValueError):
            claim["confidence"] = 0.0
        claim["verdict"] = str(claim.get("verdict") or "unverified")
        claim["impact"] = str(claim.get("impact") or "normal")
        claims.append(claim)
    payload["claims"] = claims
    payload["normalized_at"] = iso_now()
    save_json(path, payload)
    return payload


def normalize_coverage_report(workspace: Path) -> dict:
    path = workspace / "tmp" / "coverage_report.json"
    payload = load_json(path, {})
    normalized = dict(payload)
    try:
        normalized["coverage_score"] = float(normalized.get("coverage_score", 0.0))
    except (TypeError, ValueError):
        normalized["coverage_score"] = 0.0
    normalized["publication_ready"] = bool(normalized.get("publication_ready"))
    normalized["covered_questions"] = [str(value) for value in ensure_list(normalized.get("covered_questions")) if str(value).strip()]
    normalized["open_questions"] = [str(value) for value in ensure_list(normalized.get("open_questions")) if str(value).strip()]
    normalized["gaps"] = [str(value) for value in ensure_list(normalized.get("gaps")) if str(value).strip()]
    normalized["quality_notes"] = [str(value) for value in ensure_list(normalized.get("quality_notes")) if str(value).strip()]
    normalized["evidence_gaps"] = [str(value) for value in ensure_list(normalized.get("evidence_gaps")) if str(value).strip()]
    normalized["encoding_hygiene_issues"] = [str(value) for value in ensure_list(normalized.get("encoding_hygiene_issues")) if str(value).strip()]
    normalized["normalized_at"] = iso_now()
    save_json(path, normalized)
    return normalized


def main() -> int:
    parser = argparse.ArgumentParser(description="Normalize Deep Research JSON artifacts")
    parser.add_argument("--workspace", default=".", help="Workspace root")
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    source_registry = normalize_source_registry(workspace)
    claim_ledger = normalize_claim_ledger(workspace)
    coverage_report = normalize_coverage_report(workspace)
    print(json.dumps(
        {
            "status": "ok",
            "source_count": len(source_registry.get("sources", [])),
            "claim_count": len(claim_ledger.get("claims", [])),
            "coverage_score": coverage_report.get("coverage_score", 0.0),
        },
        ensure_ascii=True,
        indent=2,
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
