#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import textwrap
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def post_json(base_url: str, endpoint: str, payload: dict, timeout_sec: int) -> dict:
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}{endpoint}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_sec) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{endpoint} returned HTTP {exc.code}: {body}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"{endpoint} request failed: {exc}") from exc


def get_json(base_url: str, endpoint: str, timeout_sec: int) -> dict:
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}{endpoint}",
        headers={"Content-Type": "application/json"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_sec) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{endpoint} returned HTTP {exc.code}: {body}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"{endpoint} request failed: {exc}") from exc


def ns_to_s(value) -> float:
    try:
        return float(value) / 1_000_000_000.0
    except (TypeError, ValueError):
        return 0.0


def tps(count, duration_ns) -> float:
    seconds = ns_to_s(duration_ns)
    if seconds <= 0:
        return 0.0
    try:
        return float(count) / seconds
    except (TypeError, ValueError):
        return 0.0


def preview(text: str, limit: int = 120) -> str:
    collapsed = " ".join((text or "").strip().split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 3] + "..."


def unload_model(container_name: str, model: str) -> dict:
    proc = subprocess.run(
        ["docker", "exec", container_name, "ollama", "stop", model],
        capture_output=True,
        text=True,
        check=False,
    )
    output = "\n".join(part for part in (proc.stdout.strip(), proc.stderr.strip()) if part).strip()
    normalized = output.lower()
    if proc.returncode == 0:
        return {"result": "unloaded", "detail": output}
    if (
        "not running" in normalized
        or "not found" in normalized
        or "couldn't find model" in normalized
        or "no such model" in normalized
    ):
        return {"result": "already-unloaded", "detail": output}
    return {"result": "error", "detail": output or f"docker exec returned {proc.returncode}"}


def discover_models(base_url: str, timeout_sec: int) -> list[dict]:
    tags = get_json(base_url, "/api/tags", timeout_sec).get("models", [])
    discovered = []
    for entry in tags:
        name = entry.get("name")
        if not name:
            continue
        show = post_json(base_url, "/api/show", {"model": name, "verbose": False}, timeout_sec)
        capabilities = show.get("capabilities") or []
        discovered.append(
            {
                "name": name,
                "digest": entry.get("digest"),
                "size": entry.get("size"),
                "modified_at": entry.get("modified_at"),
                "details": entry.get("details") or show.get("details") or {},
                "capabilities": capabilities,
                "show": show,
            }
        )
    return discovered


def filter_models(models: list[dict], selected_models: list[str]) -> list[dict]:
    selected_set = {item for item in selected_models if item}
    filtered = []
    for entry in models:
        if "completion" not in (entry.get("capabilities") or []):
            continue
        if selected_set and entry["name"] not in selected_set:
            continue
        filtered.append(entry)
    return filtered


def sort_models(models: list[dict], sort_key: str) -> list[dict]:
    if sort_key == "size-asc":
        return sorted(models, key=lambda item: (item.get("size") or 0, item["name"]))
    if sort_key == "size-desc":
        return sorted(models, key=lambda item: (-(item.get("size") or 0), item["name"]))
    return sorted(models, key=lambda item: item["name"])


def run_generate(base_url: str, timeout_sec: int, payload: dict) -> dict:
    started_at = time.time()
    response = post_json(base_url, "/api/generate", payload, timeout_sec)
    finished_at = time.time()
    response["_wall_clock_seconds"] = round(finished_at - started_at, 6)
    return response


def benchmark_model(
    base_url: str,
    timeout_sec: int,
    container_name: str,
    chapter_text: str,
    model_entry: dict,
    unload_before_each: bool,
) -> dict:
    model = model_entry["name"]
    record = {
        "model": model,
        "digest": model_entry.get("digest"),
        "size_bytes": model_entry.get("size"),
        "modified_at": model_entry.get("modified_at"),
        "capabilities": model_entry.get("capabilities") or [],
        "details": model_entry.get("details") or {},
        "status": "ok",
        "unload_before_each": unload_before_each,
    }

    if unload_before_each:
        unload_info = unload_model(container_name, model)
        record["pre_run_unload"] = unload_info
        if unload_info["result"] == "error":
            record["status"] = "error"
            record["error"] = f"unable to cold-unload model before benchmark: {unload_info['detail']}"
            return record

    try:
        hello_response = run_generate(
            base_url,
            timeout_sec,
            {
                "model": model,
                "prompt": "Hello",
                "stream": False,
                "options": {"num_predict": 64},
            },
        )
        record["hello"] = {
            "load_duration_seconds": round(ns_to_s(hello_response.get("load_duration")), 6),
            "total_duration_seconds": round(ns_to_s(hello_response.get("total_duration")), 6),
            "prompt_eval_count": hello_response.get("prompt_eval_count", 0),
            "prompt_eval_duration_seconds": round(ns_to_s(hello_response.get("prompt_eval_duration")), 6),
            "eval_count": hello_response.get("eval_count", 0),
            "eval_duration_seconds": round(ns_to_s(hello_response.get("eval_duration")), 6),
            "tokens_per_second": round(
                tps(hello_response.get("eval_count", 0), hello_response.get("eval_duration", 0)),
                3,
            ),
            "wall_clock_seconds": hello_response["_wall_clock_seconds"],
            "response_preview": preview(hello_response.get("response", "")),
        }

        summary_prompt = textwrap.dedent(
            f"""\
            Voici le premier chapitre complet de "Vingt mille lieues sous les mers".
            Resume-le en 5 phrases maximum.

            {chapter_text}
            """
        ).strip()

        summary_response = run_generate(
            base_url,
            timeout_sec,
            {
                "model": model,
                "prompt": summary_prompt,
                "stream": False,
                "options": {"num_predict": 256},
            },
        )
        record["chapter_summary"] = {
            "chapter_characters": len(chapter_text),
            "load_duration_seconds": round(ns_to_s(summary_response.get("load_duration")), 6),
            "total_duration_seconds": round(ns_to_s(summary_response.get("total_duration")), 6),
            "prompt_eval_count": summary_response.get("prompt_eval_count", 0),
            "prompt_eval_duration_seconds": round(ns_to_s(summary_response.get("prompt_eval_duration")), 6),
            "prompt_tokens_per_second": round(
                tps(
                    summary_response.get("prompt_eval_count", 0),
                    summary_response.get("prompt_eval_duration", 0),
                ),
                3,
            ),
            "eval_count": summary_response.get("eval_count", 0),
            "eval_duration_seconds": round(ns_to_s(summary_response.get("eval_duration")), 6),
            "summary_tokens_per_second": round(
                tps(summary_response.get("eval_count", 0), summary_response.get("eval_duration", 0)),
                3,
            ),
            "wall_clock_seconds": summary_response["_wall_clock_seconds"],
            "response_preview": preview(summary_response.get("response", "")),
        }
    except Exception as exc:  # noqa: BLE001
        record["status"] = "error"
        record["error"] = str(exc)
    finally:
        record["post_run_unload"] = unload_model(container_name, model)

    return record


def format_text_summary(report: dict) -> str:
    lines = []
    lines.append(f"ollama_chat_bench_run_id={report['run_id']}")
    lines.append(f"profile={report['profile']}")
    lines.append(f"ollama_url={report['ollama_url']}")
    lines.append(f"chapter_file={report['chapter_file']}")
    lines.append(f"model_count={len(report['models'])}")
    lines.append("")
    lines.append(
        "MODEL\tSTATUS\tLOAD_S\tHELLO_TPS\tCHAPTER_PRELOAD_S\tCHAPTER_PRELOAD_TPS\tSUMMARY_TPS"
    )
    for item in report["models"]:
        hello = item.get("hello") or {}
        chapter_summary = item.get("chapter_summary") or {}
        lines.append(
            "\t".join(
                [
                    item["model"],
                    item.get("status", "unknown"),
                    f"{hello.get('load_duration_seconds', 0.0):.3f}",
                    f"{hello.get('tokens_per_second', 0.0):.3f}",
                    f"{chapter_summary.get('prompt_eval_duration_seconds', 0.0):.3f}",
                    f"{chapter_summary.get('prompt_tokens_per_second', 0.0):.3f}",
                    f"{chapter_summary.get('summary_tokens_per_second', 0.0):.3f}",
                ]
            )
        )
    return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Benchmark installed Ollama completion models with a cold Hello request "
            "and a chapter-summary request."
        )
    )
    parser.add_argument("--ollama-url", default=os.environ.get("OLLAMA_API_URL", "http://127.0.0.1:11434"))
    parser.add_argument("--ollama-container", required=True)
    parser.add_argument("--chapter-file", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--request-timeout-sec", type=int, default=900)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--sort", choices=("name", "size-asc", "size-desc"), default="name")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    parser.add_argument("--skip-unload", action="store_true")
    parser.add_argument("--model", action="append", default=[], help="Benchmark only the named model; repeatable.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    chapter_path = Path(args.chapter_file)
    if not chapter_path.is_file():
        die(f"chapter file not found: {chapter_path}")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    chapter_text = chapter_path.read_text(encoding="utf-8").strip()
    if not chapter_text:
        die(f"chapter file is empty: {chapter_path}")

    discovered = discover_models(args.ollama_url, args.request_timeout_sec)
    completion_models = sort_models(filter_models(discovered, args.model), args.sort)
    if args.limit > 0:
        completion_models = completion_models[: args.limit]
    if not completion_models:
        die("no installed Ollama completion/chat models matched the current selection")

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report = {
        "run_id": run_id,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "profile": os.environ.get("AGENTIC_PROFILE", "unknown"),
        "ollama_url": args.ollama_url,
        "ollama_container": args.ollama_container,
        "chapter_file": str(chapter_path),
        "model_selection": args.model,
        "sort": args.sort,
        "limit": args.limit,
        "skip_unload": args.skip_unload,
        "models": [],
    }

    for entry in completion_models:
        report["models"].append(
            benchmark_model(
                base_url=args.ollama_url,
                timeout_sec=args.request_timeout_sec,
                container_name=args.ollama_container,
                chapter_text=chapter_text,
                model_entry=entry,
                unload_before_each=not args.skip_unload,
            )
        )

    report_path = output_dir / "report.json"
    text_path = output_dir / "summary.tsv"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    text_path.write_text(format_text_summary(report), encoding="utf-8")

    print(f"ollama_chat_bench_report={report_path}")
    print(f"ollama_chat_bench_summary={text_path}")
    if args.emit_json:
        print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
