#!/usr/bin/env python3
"""Controlled, opt-in Codex context-window saturation campaign."""

import argparse
import json
import math
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from codex_context_window_benchmark import (
    build_load_prompt,
    configured_context_window,
    context_fill_percent,
    die,
    download_text,
    load_manifest,
    load_text,
    print_verbose,
    run_codex_turn,
    sha256_file,
    split_text_into_chunks,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run an opt-in controlled Codex context-window saturation campaign."
    )
    parser.add_argument("--codex-container", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--corpus-manifest")
    parser.add_argument("--request-timeout-sec", type=int, default=1800)
    parser.add_argument("--download-timeout-sec", type=int, default=120)
    parser.add_argument("--max-chars-per-load-turn", type=int, default=50000)
    parser.add_argument("--context-window", type=int)
    parser.add_argument("--target-percent", type=float, default=90.0)
    parser.add_argument("--hard-stop-percent", type=float, default=95.0)
    parser.add_argument("--model", default=os.environ.get("AGENTIC_DEFAULT_MODEL", "unknown"))
    parser.add_argument("--workdir", default="/workspace")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if not 0 < args.target_percent < 100:
        parser.error("--target-percent must be between 0 and 100")
    if not 0 < args.hard_stop_percent < 100:
        parser.error("--hard-stop-percent must be between 0 and 100")
    if args.target_percent >= args.hard_stop_percent:
        parser.error("--target-percent must be lower than --hard-stop-percent")
    if args.max_chars_per_load_turn <= 0:
        parser.error("--max-chars-per-load-turn must be positive")
    return args


def write_report(output_dir: Path, payload: dict) -> tuple[Path, Path]:
    json_path = output_dir / "codex-context-saturation.json"
    report_path = output_dir / "codex-context-saturation.md"
    json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    last = payload.get("last_accepted_turn") or {}
    lines = [
        "# Test de saturation contrôlée du contexte Codex",
        "",
        f"- Statut : `{payload['status']}`",
        f"- Mode dry-run : `{payload['dry_run']}`",
        f"- Modèle : `{payload['model']}`",
        f"- Fenêtre configurée : `{payload['context_window_tokens']}` tokens",
        f"- Cible : `{payload['target_percent']}`%",
        f"- Seuil d’arrêt dur : `{payload['hard_stop_percent']}`%",
        f"- Dernier tour accepté : `{last.get('turn_index', 'aucun')}`",
        f"- Pic d’occupation : `{payload.get('peak_fill_percent')}`%",
        "",
        "## Corpus et empreintes",
        "",
    ]
    for book in payload["books"]:
        lines.append(f"- {book['title']} — `{book['bytes']}` octets — SHA-256 `{book['sha256']}`")
    lines.extend(["", "## Dernier tour accepté", "", "```json", json.dumps(last, ensure_ascii=False, indent=2), "```", ""])
    report_path.write_text("\n".join(lines), encoding="utf-8")
    return report_path, json_path


def safe_chunk_chars(previous_tokens: int, context_window: int, hard_stop_percent: float) -> int:
    """Reserve framing/headroom and cap text using a deliberately conservative ratio."""
    hard_stop_tokens = math.floor(context_window * hard_stop_percent / 100.0)
    available_tokens = hard_stop_tokens - previous_tokens - 4096
    if available_tokens <= 2000:
        return 0
    # Live Codex turns can account for more than one token per source character
    # once session framing and resumed history are included. Two is intentional.
    return max(1000, math.floor(available_tokens / 2.0))


def main() -> int:
    args = parse_args()
    context_window = configured_context_window(args.context_window)
    if not context_window:
        die("a context window is required; use --context-window or AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW")

    output_dir = Path(args.output_dir)
    downloads_dir = output_dir / "downloads"
    turns_dir = output_dir / "turns"
    downloads_dir.mkdir(parents=True, exist_ok=True)
    turns_dir.mkdir(parents=True, exist_ok=True)
    started_at = datetime.now(timezone.utc).isoformat()

    books = []
    manifest = load_manifest(Path(args.corpus_manifest)) if args.corpus_manifest else load_manifest(None)
    for book in manifest:
        destination = downloads_dir / f"{book['id']}.txt"
        resolved_url = download_text([book["url"], *book.get("fallback_urls", [])], destination, args.download_timeout_sec)
        text = load_text(destination)
        chunks = split_text_into_chunks(text, args.max_chars_per_load_turn)
        books.append(
            {
                "id": book["id"],
                "title": book["title"],
                "author": book["author"],
                "source_url": resolved_url,
                "download_path": str(destination),
                "bytes": destination.stat().st_size,
                "sha256": sha256_file(destination),
                "characters": len(text),
                "chunks": len(chunks),
                "_chunks": chunks,
            }
        )
        print_verbose(f"[download] {book['title']} chunks={len(chunks)}", enabled=args.verbose)

    total_chunks = sum(book["chunks"] for book in books)
    if args.dry_run:
        # Conservative planning estimate: one token per three UTF-8 characters,
        # plus a small framing allowance per turn.
        estimated = 0
        planned = []
        status = "dry-run"
        for book in books:
            for part_index, chunk in enumerate(book["_chunks"], start=1):
                estimated += math.ceil(len(chunk) / 3) + 256
                fill = context_fill_percent(estimated, context_window)
                if fill is not None and fill >= args.hard_stop_percent:
                    status = "hard-stop-preflight"
                    break
                planned.append({"book": book["title"], "part_index": part_index, "chunk_chars": len(chunk), "estimated_input_tokens": estimated, "estimated_fill_percent": fill})
                if fill >= args.target_percent:
                    status = "target-reachable"
                    break
            if status == "target-reachable":
                break
        peak = planned[-1]["estimated_fill_percent"] if planned else 0.0
        for book in books:
            book.pop("_chunks")
        payload = {
            "status": status,
            "dry_run": True,
            "started_at": started_at,
            "finished_at": datetime.now(timezone.utc).isoformat(),
            "model": args.model,
            "context_window_tokens": context_window,
            "target_percent": args.target_percent,
            "hard_stop_percent": args.hard_stop_percent,
            "total_chunks": total_chunks,
            "planned_turns": planned,
            "last_accepted_turn": planned[-1] if planned else {},
            "peak_fill_percent": peak,
            "books": books,
        }
        report_path, json_path = write_report(output_dir, payload)
        print(f"codex_context_saturation_report={report_path}")
        print(f"codex_context_saturation_json={json_path}")
        if args.json:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    session_id = None
    accepted = []
    status = "corpus-exhausted"
    peak = 0.0
    turn_index = 0
    for book in books:
        part_index = 0
        for original_chunk in book.pop("_chunks"):
            pending_chunk = original_chunk
            while pending_chunk:
                previous_tokens = accepted[-1]["input_tokens"] if accepted else 0
                # Size toward the target; the independent hard-stop preflight
                # below remains the final safety gate.
                chunk_limit = safe_chunk_chars(previous_tokens, context_window, args.target_percent)
                if chunk_limit <= 0:
                    status = "hard-stop-preflight"
                    break
                chunk = pending_chunk[:chunk_limit]
                pending_chunk = pending_chunk[len(chunk):]
                part_index += 1
                # Do not start a turn whose conservative estimate would cross
                # the hard stop. The actual Codex-reported usage remains authoritative.
                estimated_tokens = previous_tokens + math.ceil(len(chunk) * 2) + 4096
                estimated_fill = context_fill_percent(estimated_tokens, context_window) or 0.0
                if estimated_fill >= args.hard_stop_percent:
                    status = "hard-stop-preflight"
                    break
                turn_index += 1
                output_jsonl = turns_dir / f"{turn_index:04d}-{book['id']}-part-{part_index:04d}.jsonl"
                result = run_codex_turn(
                    codex_container=args.codex_container,
                    prompt=build_load_prompt(book, chunk, part_index, book["chunks"]),
                    output_jsonl=output_jsonl,
                    timeout_sec=args.request_timeout_sec,
                    session_id=session_id,
                    model=args.model,
                    workdir=args.workdir,
                )
                session_id = str(result["thread_id"])
                input_tokens = int(result["usage"].get("input_tokens") or 0)
                fill = context_fill_percent(input_tokens, context_window)
                accepted.append({"turn_index": turn_index, "book": book["title"], "part_index": part_index, "chunk_chars": len(chunk), "input_tokens": input_tokens, "cached_input_tokens": int(result["usage"].get("cached_input_tokens") or 0), "context_fill_percent": fill, "output_jsonl": str(output_jsonl)})
                peak = max(peak, fill or 0.0)
                print_verbose(f"[saturation] {book['title']} part={part_index} input_tokens={input_tokens} fill={fill}%", enabled=args.verbose)
                if fill is not None and fill >= args.hard_stop_percent:
                    status = "hard-stop-observed"
                    break
                if fill is not None and fill >= args.target_percent:
                    status = "target-reached"
                    break
            if status != "corpus-exhausted":
                break
        if status != "corpus-exhausted":
            break

    payload = {
        "status": status,
        "dry_run": False,
        "started_at": started_at,
        "finished_at": datetime.now(timezone.utc).isoformat(),
        "codex_thread_id": session_id,
        "model": args.model,
        "context_window_tokens": context_window,
        "target_percent": args.target_percent,
        "hard_stop_percent": args.hard_stop_percent,
        "total_chunks": total_chunks,
        "accepted_turns": accepted,
        "last_accepted_turn": accepted[-1] if accepted else {},
        "peak_fill_percent": peak,
        "books": books,
    }
    report_path, json_path = write_report(output_dir, payload)
    print(f"codex_context_saturation_report={report_path}")
    print(f"codex_context_saturation_json={json_path}")
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
