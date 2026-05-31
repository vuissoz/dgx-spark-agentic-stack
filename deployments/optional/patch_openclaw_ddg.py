#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


ENDPOINT_OLD = 'const DDG_HTML_ENDPOINT = "https://html.duckduckgo.com/html";'
ENDPOINT_NEW = 'const DDG_HTML_ENDPOINT = "https://html.duckduckgo.com/html/";'

QUERY_BLOCK_RE = re.compile(
    r'const url = new URL\(DDG_HTML_ENDPOINT\);\n'
    r'\turl\.searchParams\.set\("q", params\.query\);\n'
    r'\tif \(region\) url\.searchParams\.set\("kl", region\);\n'
    r'\turl\.searchParams\.set\("kp", DDG_SAFE_SEARCH_PARAM\[safeSearch\]\);'
)

QUERY_BLOCK_NEW = (
    'const body = new URLSearchParams();\n'
    '\tbody.set("q", params.query);\n'
    '\tbody.set("kl", region ?? "us-en");\n'
    '\tbody.set("kp", DDG_SAFE_SEARCH_PARAM[safeSearch]);'
)

REQUEST_BLOCK_RE = re.compile(
    r'url: url\.toString\(\),\n'
    r'\t\ttimeoutSeconds,\n'
    r'\t\tinit: \{\n'
    r'\t\t\tmethod: "GET",\n'
    r'\t\t\theaders: \{ "User-Agent": "Mozilla/5\.0 \(X11; Linux x86_64\) AppleWebKit/537\.36 \(KHTML, like Gecko\) Chrome/122\.0\.0\.0 Safari/537\.36" \}\n'
    r'\t\t\}'
)

REQUEST_BLOCK_NEW = (
    'url: DDG_HTML_ENDPOINT,\n'
    '\t\ttimeoutSeconds,\n'
    '\t\tinit: {\n'
    '\t\t\tmethod: "POST",\n'
    '\t\t\theaders: { "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36", "Content-Type": "application/x-www-form-urlencoded" },\n'
    '\t\t\tbody: body.toString()\n'
    '\t\t}'
)


def patch_text(text: str) -> tuple[str, bool]:
    original = text
    text = text.replace(ENDPOINT_OLD, ENDPOINT_NEW)
    text = QUERY_BLOCK_RE.sub(QUERY_BLOCK_NEW, text, count=1)
    text = REQUEST_BLOCK_RE.sub(REQUEST_BLOCK_NEW, text, count=1)
    return text, text != original


def patch_file(path: Path) -> bool:
    raw = path.read_text(encoding="utf-8")
    if 'method: "POST"' in raw and 'body.toString()' in raw:
        return False
    patched, changed = patch_text(raw)
    if changed:
        path.write_text(patched, encoding="utf-8")
    return changed


def iter_candidates(root: Path) -> list[Path]:
    return sorted(root.rglob("ddg-client-*.js"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Patch OpenClaw DuckDuckGo client to use POST requests.")
    parser.add_argument("roots", nargs="+", help="Directories to scan for ddg-client-*.js files")
    parser.add_argument("--require-match", action="store_true", help="Fail when no candidate file is found")
    args = parser.parse_args()

    changed = 0
    seen = 0
    for root_arg in args.roots:
        root = Path(root_arg)
        if not root.exists():
            continue
        for candidate in iter_candidates(root):
            seen += 1
            if patch_file(candidate):
                changed += 1
                print(f"patched {candidate}")

    if args.require_match and seen == 0:
        print("no ddg-client-*.js candidates found", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
