#!/usr/bin/env python3
"""Check structural drift between English and French README variants."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


PLACEHOLDER_RE = re.compile(r"<[^>]+>")
COMMENT_RE = re.compile(r"^\s*#")
PATH_PLACEHOLDER_RE = re.compile(r"/(?:path|chemin)(?:/[A-Za-z0-9_.-]+)+")
SPACE_RE = re.compile(r"\s+")


@dataclass(frozen=True)
class Event:
    kind: str
    value: str
    line: int


def fail(message: str) -> int:
    sys.stderr.write(f"FAIL: {message}\n")
    return 1


def normalize_code_line(line: str) -> str:
    line = line.strip()
    line = PLACEHOLDER_RE.sub("<placeholder>", line)
    line = PATH_PLACEHOLDER_RE.sub("<path>", line)
    line = SPACE_RE.sub(" ", line)
    return line


def code_signature(info: str, lines: list[str]) -> str:
    normalized_lines: list[str] = []
    for raw_line in lines:
        if info in {"bash", "sh", "shell", "powershell", "text"} and COMMENT_RE.match(raw_line):
            continue
        line = normalize_code_line(raw_line)
        if line:
            normalized_lines.append(line)
    return f"{info or 'plain'}|" + " || ".join(normalized_lines)


def parse_events(path: Path) -> list[Event]:
    events: list[Event] = []
    in_code = False
    code_info = ""
    code_lines: list[str] = []
    code_start = 0

    for lineno, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if raw_line.startswith("```"):
            if not in_code:
                in_code = True
                code_info = raw_line[3:].strip().lower()
                code_lines = []
                code_start = lineno
            else:
                events.append(Event("code", code_signature(code_info, code_lines), code_start))
                in_code = False
                code_info = ""
                code_lines = []
            continue
        if in_code:
            code_lines.append(raw_line)
            continue
        if raw_line.startswith("#"):
            level = len(raw_line) - len(raw_line.lstrip("#"))
            events.append(Event("heading", f"h{level}", lineno))
    if in_code:
        raise SystemExit(f"{path}: unterminated fenced code block starting at line {code_start}")
    return events


def compare_event_streams(left_path: Path, right_path: Path) -> None:
    left_events = parse_events(left_path)
    right_events = parse_events(right_path)

    if len(left_events) != len(right_events):
        raise SystemExit(
            f"{left_path.name} and {right_path.name} drifted: event count differs "
            f"({len(left_events)} vs {len(right_events)})"
        )

    for index, (left, right) in enumerate(zip(left_events, right_events), 1):
        if left.kind != right.kind or left.value != right.value:
            raise SystemExit(
                f"{left_path.name} and {right_path.name} drifted at event {index}: "
                f"{left.kind}@{left.line}={left.value!r} vs {right.kind}@{right.line}={right.value!r}"
            )


def ensure_root_links(path: Path, targets: list[Path]) -> None:
    text = path.read_text(encoding="utf-8")
    missing = []
    for target in targets:
        link_pattern = re.compile(rf"\[[^\]]+\]\({re.escape(target.name)}\)")
        if not link_pattern.search(text):
            missing.append(target.name)
    if missing:
        raise SystemExit(f"{path.name} is missing README links: {', '.join(missing)}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check README translation drift.")
    parser.add_argument("--readme-root", type=Path, default=Path("README.md"))
    parser.add_argument("--readme-en", type=Path, default=Path("README.en.md"))
    parser.add_argument("--readme-fr", type=Path, default=Path("README.fr.md"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    readme_root = args.readme_root.resolve()
    readme_en = args.readme_en.resolve()
    readme_fr = args.readme_fr.resolve()

    for path in (readme_root, readme_en, readme_fr):
        if not path.is_file():
            return fail(f"missing README file: {path}")

    try:
        ensure_root_links(readme_root, [readme_en, readme_fr])
        compare_event_streams(readme_en, readme_fr)
    except SystemExit as exc:
        return fail(str(exc))

    print(
        "OK: README translation drift check passed "
        f"({readme_en.name} vs {readme_fr.name}; {readme_root.name} links intact)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
