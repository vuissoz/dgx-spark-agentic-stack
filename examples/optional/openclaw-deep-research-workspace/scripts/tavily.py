#!/usr/bin/env python3
"""
Local Tavily adapter for the research agent.
Uses the Tavily Search API and can optionally append normalized results
into the research run artifacts inside tmp/.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


sys.stdout.reconfigure(encoding="utf-8")

API_URL = "https://api.tavily.com/search"
USER_AGENT = "OpenClaw-Researcher-Tavily/2.2"


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def normalize_domain(url: str) -> str:
    return urlparse(url).netloc.lower()


def parse_domain_list(values: list[str] | None) -> list[str]:
    if not values:
        return []
    items: list[str] = []
    for value in values:
        parts = [part.strip() for part in value.split(",") if part.strip()]
        items.extend(parts)
    return items


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return default


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def load_env_file(path: Path) -> None:
    # Best-effort .env loading so the research agent does not waste steps hunting for keys.
    if not path.exists():
        return
    try:
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value
    except OSError:
        return


def bootstrap_env() -> None:
    candidates: list[Path] = []
    openclaw_base = os.getenv("OPENCLAW_BASE", "").strip()
    if openclaw_base:
        candidates.append(Path(openclaw_base) / ".env")

    script_dir = Path(__file__).resolve().parent
    workspace_researcher = script_dir.parent
    candidates.extend(
        [
            workspace_researcher / ".env",
            workspace_researcher.parent / ".env",
            Path.home() / ".openclaw" / ".env",
        ]
    )

    seen = set()
    for path in candidates:
        resolved = path.resolve() if path.exists() else path
        if str(resolved) in seen:
            continue
        seen.add(str(resolved))
        load_env_file(path)


def resolve_api_key(explicit_key: str | None) -> str | None:
    if explicit_key:
        return explicit_key
    bootstrap_env()
    return os.getenv("TAVILY_API_KEY")


def classify_source_type(url: str) -> str:
    domain = normalize_domain(url)
    primary_markers = [
        ".gov",
        ".edu",
        "github.com",
        "huggingface.co",
        "arxiv.org",
        "docs.",
    ]
    secondary_markers = ["wikipedia.org", "medium.com", "substack.com"]
    if any(marker in domain for marker in primary_markers):
        return "primary"
    if any(marker in domain for marker in secondary_markers):
        return "secondary"
    return "tertiary"


def build_payload(args: argparse.Namespace, api_key: str) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "api_key": api_key,
        "query": args.query,
        "search_depth": args.search_depth,
        "topic": args.topic,
        "max_results": args.max_results,
        "include_answer": args.include_answer,
        "include_raw_content": args.include_raw_content,
        "include_images": args.include_images,
        "include_image_descriptions": args.include_image_descriptions,
        "include_favicon": args.include_favicon,
        "include_usage": args.include_usage,
        "auto_parameters": args.auto_parameters,
    }

    include_domains = parse_domain_list(args.include_domains)
    exclude_domains = parse_domain_list(args.exclude_domains)
    if include_domains:
        payload["include_domains"] = include_domains
    if exclude_domains:
        payload["exclude_domains"] = exclude_domains
    if args.country:
        payload["country"] = args.country
    if args.time_range:
        payload["time_range"] = args.time_range
    if args.start_date:
        payload["start_date"] = args.start_date
    if args.end_date:
        payload["end_date"] = args.end_date

    return payload


def redact_payload(payload: dict[str, Any]) -> dict[str, Any]:
    # Prevent secret material from leaking into reproducibility artifacts.
    cleaned = dict(payload)
    if "api_key" in cleaned:
        cleaned["api_key"] = "***redacted***"
    return cleaned


def tavily_search(payload: dict[str, Any]) -> dict[str, Any]:
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
    )

    for attempt in range(2):
        try:
            with urllib.request.urlopen(req, timeout=45) as response:
                data = json.load(response)
                return {"success": True, "data": data}
        except urllib.error.HTTPError as exc:
            if exc.code == 429 and attempt == 0:
                time.sleep(2)
                continue
            return {"success": False, "error": f"HTTP {exc.code}: {exc.reason}"}
        except urllib.error.URLError as exc:
            return {"success": False, "error": f"Network Error: {exc.reason}"}
        except Exception as exc:
            return {"success": False, "error": f"Unexpected Error: {exc}"}
    return {"success": False, "error": "Rate limit exceeded after retry"}


def append_query_log(path: Path, query: str, query_family: str, payload: dict[str, Any], response: dict[str, Any]) -> None:
    # Records the exact search call so scout decisions remain reproducible.
    data = load_json(path, {"queries": []})
    data.setdefault("queries", []).append(
        {
            "ts": iso_now(),
            "provider": "tavily",
            "query": query,
            "query_family": query_family,
            "payload": redact_payload(payload),
            "result_count": len(response.get("results", [])),
            "response_time": response.get("response_time"),
            "result_urls": [item.get("url") for item in response.get("results", []) if item.get("url")],
        }
    )
    save_json(path, data)


def append_source_registry(path: Path, response: dict[str, Any], query_family: str) -> None:
    # Normalizes Tavily results into source records used later by verification.
    data = load_json(path, {"sources": []})
    existing_urls = {item.get("url") for item in data.get("sources", [])}
    for index, item in enumerate(response.get("results", []), start=1):
        url = item.get("url")
        if not url or url in existing_urls:
            continue
        data.setdefault("sources", []).append(
            {
                "url": url,
                "title": item.get("title") or url,
                "domain": normalize_domain(url),
                "source_type": classify_source_type(url),
                "freshness": "unknown",
                "relevance": "high" if index <= 3 else "medium",
                "fetched": False,
                "fulltext_status": "not_fetched",
                "duplicate_cluster": url,
                "query_family": query_family,
                "provider": "tavily",
                "summary": item.get("content") or "",
            }
        )
        existing_urls.add(url)
    save_json(path, data)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Search Tavily and optionally append results into Deep Research artifacts")
    parser.add_argument("query", help="Search query")
    parser.add_argument("--api-key", help="Override TAVILY_API_KEY")
    parser.add_argument("--search-depth", default="advanced", choices=["basic", "advanced"])
    parser.add_argument("--topic", default="general")
    parser.add_argument("--max-results", type=int, default=8)
    parser.add_argument("--include-answer", action="store_true")
    parser.add_argument("--include-raw-content", action="store_true")
    parser.add_argument("--include-images", action="store_true")
    parser.add_argument("--include-image-descriptions", action="store_true")
    parser.add_argument("--include-favicon", action="store_true")
    parser.add_argument("--include-usage", action="store_true")
    parser.add_argument("--auto-parameters", action="store_true")
    parser.add_argument("--include-domains", action="append")
    parser.add_argument("--exclude-domains", action="append")
    parser.add_argument("--country")
    parser.add_argument("--time-range")
    parser.add_argument("--start-date")
    parser.add_argument("--end-date")
    parser.add_argument("--query-family", default="baseline")
    parser.add_argument("--append-query-log")
    parser.add_argument("--append-source-registry")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    api_key = resolve_api_key(args.api_key)
    if not api_key:
        print(json.dumps({"success": False, "error": "Missing TAVILY_API_KEY"}, ensure_ascii=False, indent=2))
        return 1

    payload = build_payload(args, api_key)
    result = tavily_search(payload)
    if not result.get("success"):
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 1

    data = result["data"]
    if args.append_query_log:
        append_query_log(Path(args.append_query_log).resolve(), args.query, args.query_family, payload, data)
    if args.append_source_registry:
        append_source_registry(Path(args.append_source_registry).resolve(), data, args.query_family)

    print(json.dumps(data, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
