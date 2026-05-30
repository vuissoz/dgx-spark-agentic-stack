#!/usr/bin/env python3
"""Materialize discovery-only query results into the source registry."""

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


def normalize_url(url: str) -> str:
    parsed = urlparse((url or "").strip())
    path_part = (parsed.path or "").rstrip("/")
    return f"{parsed.scheme}://{parsed.netloc}{path_part}" if parsed.scheme and parsed.netloc else (url or "").strip().rstrip("/")


def domain_of(url: str) -> str:
    return urlparse(url).netloc.lower()


def classify_source_type(url: str) -> str:
    domain = domain_of(url)
    primary_markers = (".gov", ".edu", "github.com", "huggingface.co", "arxiv.org", "docs.")
    secondary_markers = ("wikipedia.org", "medium.com", "substack.com", "blog.")
    if any(marker in domain for marker in primary_markers):
        return "primary"
    if any(marker in domain for marker in secondary_markers):
        return "secondary"
    return "tertiary"


def main() -> int:
    parser = argparse.ArgumentParser(description="Materialize web search result URLs into research artifacts")
    parser.add_argument("--provider", required=True, help="Discovery provider name")
    parser.add_argument("--query", required=True, help="Original search query")
    parser.add_argument("--query-family", default="baseline", help="Discovery query family")
    parser.add_argument("--urls", nargs="+", required=True, help="URLs to append")
    parser.add_argument("--append-query-log", required=True, help="Path to query_log.json")
    parser.add_argument("--append-source-registry", required=True, help="Path to source_registry.json")
    args = parser.parse_args()

    query_log_path = Path(args.append_query_log).resolve()
    source_registry_path = Path(args.append_source_registry).resolve()
    query_log = load_json(query_log_path, {"queries": []})
    source_registry = load_json(source_registry_path, {"sources": []})

    query_log.setdefault("queries", []).append(
        {
            "ts": iso_now(),
            "provider": args.provider,
            "query": args.query,
            "query_family": args.query_family,
            "result_urls": args.urls,
            "result_count": len(args.urls),
        }
    )

    existing = {normalize_url(item.get("url", "")) for item in source_registry.get("sources", []) if isinstance(item, dict)}
    added = 0
    for rank, url in enumerate(args.urls, start=1):
        normalized = normalize_url(url)
        if not normalized or normalized in existing:
            continue
        source_registry.setdefault("sources", []).append(
            {
                "url": url,
                "title": url,
                "domain": domain_of(url),
                "source_type": classify_source_type(url),
                "freshness": "unknown",
                "relevance": "discovery",
                "fetched": False,
                "fulltext_status": "not_fetched",
                "duplicate_cluster": normalized,
                "query_family": args.query_family,
                "provider": args.provider,
                "discovery_only": True,
                "discovery_rank": rank,
            }
        )
        existing.add(normalized)
        added += 1

    save_json(query_log_path, query_log)
    save_json(source_registry_path, source_registry)
    print(json.dumps({"status": "ok", "added": added}, ensure_ascii=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
