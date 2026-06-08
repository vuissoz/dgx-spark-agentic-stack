#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import shlex
import subprocess
import sys
import textwrap
import time
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_CORPUS = [
    {
        "id": "vingt-mille-lieues-sous-les-mers",
        "title": "Vingt mille lieues sous les mers",
        "author": "Jules Verne",
        "url": "https://www.gutenberg.org/cache/epub/5097/pg5097.txt",
        "fallback_urls": ["https://www.gutenberg.org/ebooks/5097.txt.utf-8"],
    },
    {
        "id": "ile-mysterieuse",
        "title": "L'ile mysterieuse",
        "author": "Jules Verne",
        "url": "https://www.gutenberg.org/cache/epub/14287/pg14287.txt",
        "fallback_urls": ["https://www.gutenberg.org/ebooks/14287.txt.utf-8"],
    },
    {
        "id": "voyage-au-centre-de-la-terre",
        "title": "Voyage au centre de la Terre",
        "author": "Jules Verne",
        "url": "https://www.gutenberg.org/cache/epub/4791/pg4791.txt",
        "fallback_urls": ["https://www.gutenberg.org/ebooks/4791.txt.utf-8"],
    },
    {
        "id": "de-la-terre-a-la-lune",
        "title": "De la Terre a la Lune",
        "author": "Jules Verne",
        "url": "https://www.gutenberg.org/cache/epub/799/pg799.txt",
        "fallback_urls": ["https://www.gutenberg.org/ebooks/799.txt.utf-8"],
    },
]


def die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path: Path | None) -> list[dict]:
    if path is None:
        return [dict(entry) for entry in DEFAULT_CORPUS]
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, list) or not payload:
        die(f"invalid corpus manifest: {path}")
    manifest: list[dict] = []
    for index, entry in enumerate(payload, start=1):
        if not isinstance(entry, dict):
            die(f"invalid corpus manifest entry #{index}: expected object")
        title = str(entry.get("title") or "").strip()
        url = str(entry.get("url") or "").strip()
        book_id = str(entry.get("id") or "").strip() or f"book-{index}"
        author = str(entry.get("author") or "Jules Verne").strip()
        fallback_urls = entry.get("fallback_urls") or []
        if not title or not url:
            die(f"invalid corpus manifest entry #{index}: missing title/url")
        if not isinstance(fallback_urls, list):
            die(f"invalid corpus manifest entry #{index}: fallback_urls must be a list when provided")
        manifest.append(
            {
                "id": book_id,
                "title": title,
                "author": author,
                "url": url,
                "fallback_urls": [str(value).strip() for value in fallback_urls if str(value).strip()],
            }
        )
    return manifest


def download_text(urls: list[str], destination: Path, timeout_sec: int, retries: int = 3) -> str:
    attempted: list[str] = []
    for url in urls:
        for attempt in range(1, retries + 1):
            proc = subprocess.run(
                [
                    "curl",
                    "-fsSL",
                    "--connect-timeout",
                    "15",
                    "--max-time",
                    str(timeout_sec),
                    "-A",
                    "dgx-spark-agentic-stack codex-context-window-benchmark/1.0",
                    url,
                    "-o",
                    str(destination),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if proc.returncode == 0:
                return url
            detail = (proc.stderr or proc.stdout or "").strip()
            attempted.append(f"{url} (attempt {attempt}/{retries}): {detail or f'curl exit {proc.returncode}'}")
            if attempt < retries:
                time.sleep(min(5 * attempt, 15))
    raise RuntimeError("download failed after retries: " + " | ".join(attempted))


def load_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return path.read_text(encoding="utf-8-sig")


def parse_jsonl_events(text: str) -> dict:
    events = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"invalid JSONL event from Codex: {line[:200]}") from exc
    if not events:
        raise RuntimeError("Codex emitted no JSONL events")

    thread_id = ""
    last_message = ""
    usage = None
    for entry in events:
        if entry.get("type") == "thread.started" and not thread_id:
            thread_id = str(entry.get("thread_id") or "")
        if entry.get("type") == "item.completed":
            item = entry.get("item")
            if isinstance(item, dict) and item.get("type") == "agent_message":
                text_value = item.get("text")
                if isinstance(text_value, str):
                    last_message = text_value.strip()
        if entry.get("type") == "turn.completed":
            usage_value = entry.get("usage")
            if isinstance(usage_value, dict):
                usage = usage_value
    if not thread_id:
        raise RuntimeError("Codex did not emit thread.started")
    if usage is None:
        raise RuntimeError("Codex did not emit turn.completed usage")
    return {
        "thread_id": thread_id,
        "last_message": last_message,
        "usage": usage,
        "events": events,
    }


def run_codex_turn(
    *,
    codex_container: str,
    prompt: str,
    output_jsonl: Path,
    timeout_sec: int,
    session_id: str | None = None,
    model: str | None = None,
    workdir: str,
) -> dict:
    command = ["cd", shlex.quote(workdir), "&&", "codex", "-a", "never", "-s", "workspace-write", "exec"]
    if session_id:
        command.append("resume")
    command.extend(["--skip-git-repo-check", "--json"])
    if model:
        command.extend(["-m", shlex.quote(model)])
    if session_id:
        command.append(shlex.quote(session_id))
    command.append("-")
    shell_command = " ".join(command)

    proc = subprocess.run(
        ["docker", "exec", "-i", codex_container, "sh", "-lc", shell_command],
        input=prompt,
        text=True,
        capture_output=True,
        timeout=timeout_sec,
        check=False,
    )
    output_jsonl.write_text(proc.stdout, encoding="utf-8")
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"Codex turn failed (exit={proc.returncode}): {detail}")
    parsed = parse_jsonl_events(proc.stdout)
    parsed["stderr"] = proc.stderr
    return parsed


def configured_context_window(cli_value: int | None) -> int | None:
    if cli_value is not None and cli_value > 0:
        return cli_value
    for key in ("AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW", "OLLAMA_CONTEXT_LENGTH"):
        value = (os.environ.get(key) or "").strip()
        if value.isdigit():
            return int(value)
    return None


def context_fill_percent(input_tokens: int | None, context_window_tokens: int | None) -> float | None:
    if input_tokens is None or context_window_tokens in (None, 0):
        return None
    return round((float(input_tokens) / float(context_window_tokens)) * 100.0, 2)


def print_verbose(message: str, *, enabled: bool) -> None:
    if enabled:
        print(message, file=sys.stderr, flush=True)


def render_progress_bar(current: int, total: int, width: int = 28) -> str:
    total = max(total, 1)
    current = max(0, min(current, total))
    filled = int(round((current / total) * width))
    bar = "#" * filled + "-" * (width - filled)
    percent = int(round((current / total) * 100))
    return f"[{bar}] {current}/{total} ({percent}%)"


def split_text_into_chunks(text: str, max_chars: int) -> list[str]:
    normalized = text.strip()
    if len(normalized) <= max_chars:
        return [normalized]

    chunks: list[str] = []
    current = ""
    for paragraph in normalized.split("\n\n"):
        segment = paragraph.strip()
        if not segment:
            continue
        candidate = f"{current}\n\n{segment}".strip() if current else segment
        if len(candidate) <= max_chars:
            current = candidate
            continue
        if current:
            chunks.append(current)
            current = ""
        while len(segment) > max_chars:
            chunks.append(segment[:max_chars])
            segment = segment[max_chars:]
        current = segment
    if current:
        chunks.append(current)
    return [chunk for chunk in chunks if chunk]


def build_load_prompt(book: dict, text: str, part_index: int, total_parts: int) -> str:
    return textwrap.dedent(
        f"""\
        Tu dois conserver ce roman complet dans cette meme session de contexte.
        Ceci est la partie {part_index}/{total_parts} du roman.
        Lis-la integralement, conserve-la en memoire avec les parties precedentes du meme roman, n'en fais pas encore la synthese, et reponds exactement par:
        loaded: {book["id"]} part {part_index}/{total_parts}

        Titre: {book["title"]}
        Auteur: {book["author"]}
        Source: {book["source_url"]}

        Texte integral:
        {text}
        """
    )


def build_summary_prompt(book: dict) -> str:
    return textwrap.dedent(
        f"""\
        Redige en francais une synthese du roman "{book["title"]}".
        Contraintes:
        - 10 a 14 phrases.
        - Pas de liste a puces.
        - Couvre intrigue, personnages principaux, grands themes, et singularites du roman.
        - Si des liens avec les romans Jules Verne deja charges existent, mentionne-les brievement.
        """
    )


def build_final_prompt(books: list[dict]) -> str:
    titles = ", ".join(book["title"] for book in books)
    return textwrap.dedent(
        f"""\
        A partir des syntheses deja produites pour {titles}, redige une synthese finale consolidee en francais.
        Contraintes:
        - 12 a 16 phrases.
        - Pas de liste a puces.
        - Fais ressortir les continuites thematiques, les differences de ton et de structure, et l'evolution de l'imaginaire scientifique.
        """
    )


def write_markdown_report(
    *,
    report_path: Path,
    json_path: Path,
    session_id: str,
    started_at: str,
    finished_at: str,
    context_window_tokens: int | None,
    model: str,
    books: list[dict],
    final_summary: dict,
) -> None:
    lines = [
        "# Benchmark Codex de saturation de contexte",
        "",
        f"- Debut: {started_at}",
        f"- Fin: {finished_at}",
        f"- Session Codex: `{session_id}`",
        f"- Modele: `{model}`",
        f"- Fenetre de contexte configuree: `{context_window_tokens}` tokens" if context_window_tokens else "- Fenetre de contexte configuree: inconnue",
        f"- Rapport JSON: `{json_path}`",
        "",
        "## Corpus",
        "",
    ]
    for book in books:
        lines.extend(
            [
                f"- {book['title']} ({book['source_url']})",
                f"  id={book['id']} bytes={book['bytes']} sha256={book['sha256']}",
            ]
        )
    lines.extend(["", "## Syntheses intermediaires", ""])
    for book in books:
        summary_turn = book["summary_turn"]
        lines.extend(
            [
                f"### {book['title']}",
                "",
                f"- Fenetre configuree: `{summary_turn['context_window_tokens']}`",
                f"- Input tokens: `{summary_turn['input_tokens']}`",
                f"- Cached input tokens: `{summary_turn['cached_input_tokens']}`",
                f"- Taux de remplissage: `{summary_turn['context_fill_percent']}`%",
                "",
                book["summary"],
                "",
            ]
        )
    lines.extend(
        [
            "## Synthese finale",
            "",
            f"- Fenetre configuree: `{final_summary['context_window_tokens']}`",
            f"- Input tokens: `{final_summary['input_tokens']}`",
            f"- Cached input tokens: `{final_summary['cached_input_tokens']}`",
            f"- Taux de remplissage: `{final_summary['context_fill_percent']}`%",
            "",
            final_summary["summary"],
            "",
        ]
    )
    report_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a cumulative Codex context-window benchmark with French Jules Verne corpora.")
    parser.add_argument("--codex-container", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--corpus-manifest")
    parser.add_argument("--request-timeout-sec", type=int, default=1800)
    parser.add_argument("--download-timeout-sec", type=int, default=120)
    parser.add_argument("--max-chars-per-load-turn", type=int, default=250000)
    parser.add_argument("--context-window", type=int)
    parser.add_argument("--model", default=os.environ.get("AGENTIC_DEFAULT_MODEL", "unknown"))
    parser.add_argument("--workdir", default="/workspace")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    manifest = load_manifest(Path(args.corpus_manifest)) if args.corpus_manifest else load_manifest(None)
    output_dir = Path(args.output_dir)
    downloads_dir = output_dir / "downloads"
    turns_dir = output_dir / "turns"
    downloads_dir.mkdir(parents=True, exist_ok=True)
    turns_dir.mkdir(parents=True, exist_ok=True)

    started_at = datetime.now(timezone.utc).isoformat()
    context_window_tokens = configured_context_window(args.context_window)

    books: list[dict] = []
    for book in manifest:
        destination = downloads_dir / f"{book['id']}.txt"
        print_verbose(f"[download] {book['title']}", enabled=args.verbose)
        try:
            resolved_url = download_text([book["url"], *book.get("fallback_urls", [])], destination, args.download_timeout_sec)
        except RuntimeError as exc:
            die(str(exc))
        text = load_text(destination)
        books.append(
            {
                "id": book["id"],
                "title": book["title"],
                "author": book["author"],
                "source_url": resolved_url,
                "source_candidates": [book["url"], *book.get("fallback_urls", [])],
                "download_path": str(destination),
                "bytes": destination.stat().st_size,
                "sha256": sha256_file(destination),
                "text": text,
            }
        )

    session_id = None
    for index, book in enumerate(books, start=1):
        load_chunks = split_text_into_chunks(book["text"], args.max_chars_per_load_turn)
        book["load_turns"] = []
        print_verbose(
            f"[load] {book['title']} {render_progress_bar(0, len(load_chunks))}",
            enabled=args.verbose,
        )
        for part_index, chunk_text in enumerate(load_chunks, start=1):
            load_prompt = build_load_prompt(book, chunk_text, part_index, len(load_chunks))
            load_output = turns_dir / f"{index:02d}-{book['id']}-load-part-{part_index:02d}.jsonl"
            load_result = run_codex_turn(
                codex_container=args.codex_container,
                prompt=load_prompt,
                output_jsonl=load_output,
                timeout_sec=args.request_timeout_sec,
                session_id=session_id,
                model=args.model,
                workdir=args.workdir,
            )
            session_id = str(load_result["thread_id"])
            book["load_turns"].append(
                {
                    "part_index": part_index,
                    "total_parts": len(load_chunks),
                    "output_jsonl": str(load_output),
                    "response": load_result["last_message"],
                    "usage": load_result["usage"],
                    "chunk_chars": len(chunk_text),
                }
            )
            print_verbose(
                f"[load] {book['title']} {render_progress_bar(part_index, len(load_chunks))} "
                f"chunk_chars={len(chunk_text)} input_tokens={int(load_result['usage'].get('input_tokens') or 0)}",
                enabled=args.verbose,
            )

        summary_prompt = build_summary_prompt(book)
        summary_output = turns_dir / f"{index:02d}-{book['id']}-summary.jsonl"
        summary_result = run_codex_turn(
            codex_container=args.codex_container,
            prompt=summary_prompt,
            output_jsonl=summary_output,
            timeout_sec=args.request_timeout_sec,
            session_id=session_id,
            model=args.model,
            workdir=args.workdir,
        )
        usage = summary_result["usage"]
        input_tokens = int(usage.get("input_tokens") or 0)
        cached_input_tokens = int(usage.get("cached_input_tokens") or 0)
        book["summary"] = summary_result["last_message"]
        book["summary_turn"] = {
            "output_jsonl": str(summary_output),
            "input_tokens": input_tokens,
            "cached_input_tokens": cached_input_tokens,
            "output_tokens": int(usage.get("output_tokens") or 0),
            "reasoning_output_tokens": int(usage.get("reasoning_output_tokens") or 0),
            "context_window_tokens": context_window_tokens,
            "context_fill_percent": context_fill_percent(input_tokens, context_window_tokens),
        }
        print_verbose(
            "\n".join(
                [
                    f"[summary] Texte: {book['title']}",
                    f"[summary] Input tokens={input_tokens} cached={cached_input_tokens} fill={book['summary_turn']['context_fill_percent']}%",
                    book["summary"],
                ]
            ),
            enabled=args.verbose,
        )
        del book["text"]

    final_output = turns_dir / "final-summary.jsonl"
    final_result = run_codex_turn(
        codex_container=args.codex_container,
        prompt=build_final_prompt(books),
        output_jsonl=final_output,
        timeout_sec=args.request_timeout_sec,
        session_id=session_id,
        model=args.model,
        workdir=args.workdir,
    )
    final_usage = final_result["usage"]
    final_summary = {
        "summary": final_result["last_message"],
        "output_jsonl": str(final_output),
        "input_tokens": int(final_usage.get("input_tokens") or 0),
        "cached_input_tokens": int(final_usage.get("cached_input_tokens") or 0),
        "output_tokens": int(final_usage.get("output_tokens") or 0),
        "reasoning_output_tokens": int(final_usage.get("reasoning_output_tokens") or 0),
        "context_window_tokens": context_window_tokens,
        "context_fill_percent": context_fill_percent(int(final_usage.get("input_tokens") or 0), context_window_tokens),
    }
    print_verbose(
        "\n".join(
            [
                "[summary] Texte: synthese finale",
                f"[summary] Input tokens={final_summary['input_tokens']} cached={final_summary['cached_input_tokens']} fill={final_summary['context_fill_percent']}%",
                final_summary["summary"],
            ]
        ),
        enabled=args.verbose,
    )

    finished_at = datetime.now(timezone.utc).isoformat()
    payload = {
        "status": "ok",
        "started_at": started_at,
        "finished_at": finished_at,
        "codex_thread_id": session_id,
        "model": args.model,
        "context_window_tokens": context_window_tokens,
        "books": books,
        "final_summary": final_summary,
    }

    json_path = output_dir / "codex-context-window-benchmark.json"
    report_path = output_dir / "codex-context-window-benchmark.md"
    json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_markdown_report(
        report_path=report_path,
        json_path=json_path,
        session_id=session_id or "",
        started_at=started_at,
        finished_at=finished_at,
        context_window_tokens=context_window_tokens,
        model=args.model,
        books=books,
        final_summary=final_summary,
    )

    print(f"codex_context_bench_report={report_path}")
    print(f"codex_context_bench_json={json_path}")
    print(f"codex_context_bench_thread_id={session_id}")
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"Final context fill: {final_summary['context_fill_percent']}%")
        print(final_summary["summary"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
