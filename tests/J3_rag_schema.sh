#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_J_TESTS:-0}" == "1" ]]; then
  ok "J3 skipped because AGENTIC_SKIP_J_TESTS=1"
  exit 0
fi

assert_cmd python3

runtime_schema="${AGENTIC_ROOT:-/srv/agentic}/rag/config/document.schema.json"
repo_schema="${REPO_ROOT}/deployments/rag/document.schema.json"
schema_path="${runtime_schema}"
[[ -f "${schema_path}" ]] || schema_path="${repo_schema}"
[[ -f "${schema_path}" ]] || fail "rag canonical schema is missing (checked ${runtime_schema} and ${repo_schema})"

python3 - "${schema_path}" <<'PY'
import json
import sys

schema_path = sys.argv[1]
with open(schema_path, "r", encoding="utf-8") as handle:
    schema = json.load(handle)

if schema.get("type") != "object":
    raise SystemExit(f"schema type must be object: {schema_path}")

required = set(schema.get("required", []))
expected_required = {
    "doc_id",
    "chunk_id",
    "text",
    "source_type",
    "source_path",
    "language",
    "timestamp",
    "version",
}
missing = sorted(expected_required - required)
if missing:
    raise SystemExit(f"schema required fields missing: {', '.join(missing)}")

props = schema.get("properties", {})
for field in ("repo", "branch", "commit_sha", "page", "file_path", "start_line", "end_line", "section", "title", "authors", "doi"):
    if field not in props:
        raise SystemExit(f"schema properties missing optional provenance field: {field}")

source_type = props.get("source_type", {})
allowed = set(source_type.get("enum", []))
if {"pdf", "code"} - allowed:
    raise SystemExit("source_type enum must include pdf and code")

for integer_field in ("page", "start_line", "end_line"):
    field_schema = props.get(integer_field, {})
    if field_schema.get("type") != "integer":
        raise SystemExit(f"{integer_field} must be integer")

print(f"OK: rag schema is valid for J3 skeleton ({schema_path})")
PY

ok "J3_rag_schema passed"
