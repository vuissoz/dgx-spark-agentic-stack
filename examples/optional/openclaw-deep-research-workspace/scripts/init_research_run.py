#!/usr/bin/env python3
import argparse
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def today_utc() -> str:
    return datetime.now(timezone.utc).date().isoformat()


def slugify_topic(value: str) -> str:
    cleaned = "".join(ch.lower() if ch.isalnum() else "-" for ch in str(value or "research-report"))
    while "--" in cleaned:
        cleaned = cleaned.replace("--", "-")
    return cleaned.strip("-") or "research-report"


def write_json(path: Path, payload: dict) -> None:
    # Each new run must start from a clean artifact state instead of inheriting stale files.
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def reset_tmp_dir(tmp_dir: Path) -> None:
    # Remove stale artifacts and helper files from previous runs before initializing a new task.
    if not tmp_dir.exists():
        tmp_dir.mkdir(parents=True, exist_ok=True)
        return
    for child in tmp_dir.iterdir():
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description="Initialize Deep Research run artifacts")
    parser.add_argument("--topic", required=True, help="Topic or task label")
    parser.add_argument("--language", default="user-language", help="Report language")
    parser.add_argument("--task-date", default=today_utc(), help="Task date in YYYY-MM-DD format")
    parser.add_argument("--workspace", default=".", help="Workspace root")
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    tmp_dir = workspace / "tmp"
    reports_dir = workspace / "reports"
    reports_dir.mkdir(parents=True, exist_ok=True)
    reset_tmp_dir(tmp_dir)
    report_target = reports_dir / f"{slugify_topic(args.topic)}_{args.task_date}.md"

    research_plan = {
        "topic": args.topic,
        "language": args.language,
        "task_date": args.task_date,
        "status": "initialized",
        "created_at": iso_now(),
        "report_target": str(report_target),
        "questions": [],
        "scope": {"in_scope": [], "out_of_scope": []},
        "success_criteria": [],
        "notes": [],
    }
    query_log = {"queries": []}
    source_registry = {"sources": []}
    claim_ledger = {"claims": []}
    coverage_report = {
        "coverage_score": 0.0,
        "publication_ready": False,
        "covered_questions": [],
        "open_questions": [],
        "gaps": [],
        "quality_notes": [],
        "evidence_gaps": [],
        "encoding_hygiene_issues": [],
    }

    write_json(tmp_dir / "research_plan.json", research_plan)
    write_json(tmp_dir / "query_log.json", query_log)
    write_json(tmp_dir / "source_registry.json", source_registry)
    write_json(tmp_dir / "claim_ledger.json", claim_ledger)
    write_json(tmp_dir / "coverage_report.json", coverage_report)

    print(json.dumps({
        "status": "initialized",
        "workspace": str(workspace),
        "tmp_dir": str(tmp_dir),
        "report_target": str(report_target),
        "created_at": research_plan["created_at"],
    }, ensure_ascii=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
