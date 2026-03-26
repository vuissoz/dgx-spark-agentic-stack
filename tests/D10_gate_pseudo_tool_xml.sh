#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_D_TESTS:-0}" == "1" ]]; then
  ok "D10 skipped because AGENTIC_SKIP_D_TESTS=1"
  exit 0
fi

assert_cmd python3

python3 - "${REPO_ROOT}" <<'PY'
import json
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(repo_root / "deployments" / "gate"))

from tool_call_parser import pseudo_tool_calls_from_content


tools = [
    {"type": "function", "function": {"name": "read_file", "parameters": {"type": "object"}}},
    {"type": "function", "function": {"name": "exec_command", "parameters": {"type": "object"}}},
]

cleaned, tool_calls = pseudo_tool_calls_from_content(
    "I will inspect the workspace.\n<read_file><path>/workspace/README.md</path></read_file>",
    tools,
)
if not isinstance(tool_calls, list) or len(tool_calls) != 1:
    raise SystemExit(f"expected one XML-style tool call, got {tool_calls!r}")
first = tool_calls[0]
if first["function"]["name"] != "read_file":
    raise SystemExit(f"expected read_file, got {first!r}")
args = json.loads(first["function"]["arguments"])
if args != {"path": "/workspace/README.md"}:
    raise SystemExit(f"unexpected XML-style arguments: {args!r}")
if cleaned != "I will inspect the workspace.":
    raise SystemExit(f"unexpected cleaned content for XML-style tool call: {cleaned!r}")

cleaned_wrapped, wrapped_calls = pseudo_tool_calls_from_content(
    "<tool_call><exec_command><command>pwd</command><description>show cwd</description></exec_command></tool_call>",
    tools,
)
if not isinstance(wrapped_calls, list) or len(wrapped_calls) != 1:
    raise SystemExit(f"expected one wrapped XML tool call, got {wrapped_calls!r}")
wrapped = wrapped_calls[0]
if wrapped["function"]["name"] != "exec_command":
    raise SystemExit(f"expected exec_command, got {wrapped!r}")
wrapped_args = json.loads(wrapped["function"]["arguments"])
if wrapped_args != {"command": "pwd", "description": "show cwd"}:
    raise SystemExit(f"unexpected wrapped XML arguments: {wrapped_args!r}")
if cleaned_wrapped != "":
    raise SystemExit(f"wrapped XML tool call should clean to empty content, got {cleaned_wrapped!r}")

legacy_cleaned, legacy_calls = pseudo_tool_calls_from_content(
    "<function=read_file><parameter=path>/workspace/PLAN.md</parameter></function>",
    tools,
)
if not isinstance(legacy_calls, list) or len(legacy_calls) != 1:
    raise SystemExit(f"expected one legacy pseudo tool call, got {legacy_calls!r}")
legacy = legacy_calls[0]
if legacy["function"]["name"] != "read_file":
    raise SystemExit(f"legacy pseudo tool call wrong name: {legacy!r}")
legacy_args = json.loads(legacy["function"]["arguments"])
if legacy_args != {"path": "/workspace/PLAN.md"}:
    raise SystemExit(f"unexpected legacy pseudo arguments: {legacy_args!r}")
if legacy_cleaned != "":
    raise SystemExit(f"legacy pseudo tool call should clean to empty content, got {legacy_cleaned!r}")

untouched_content = "<answer><path>/workspace/README.md</path></answer>"
untouched_cleaned, untouched_calls = pseudo_tool_calls_from_content(untouched_content, tools)
if untouched_calls is not None:
    raise SystemExit(f"non-tool XML must not be converted when tool is not declared: {untouched_calls!r}")
if untouched_cleaned != untouched_content:
    raise SystemExit(f"non-tool XML content should stay untouched, got {untouched_cleaned!r}")
PY

ok "gate pseudo tool parser converts XML-style tool tags into function calls"
ok "D10_gate_pseudo_tool_xml passed"
