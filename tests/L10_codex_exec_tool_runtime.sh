#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L10 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd timeout
assert_cmd python3

exec_timeout="${AGENTIC_CODEX_TOOL_RUNTIME_TIMEOUT_SECONDS:-240}"

codex_cid="$(require_service_container agentic-codex)" || exit 1
gate_cid="$(require_service_container ollama-gate)" || exit 1

wait_for_container_ready "${codex_cid}" 120 || fail "agentic-codex is not ready"
wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate is not ready"

probe_dir="/workspace/.l10-codex-tool-runtime"
probe_file="${probe_dir}/token.txt"
probe_token="l10_codex_tool_$(date +%s)_$RANDOM"
probe_prompt="Use tools to read ${probe_file} and output exactly the token content with no extra text."

docker exec "${codex_cid}" sh -lc "mkdir -p '${probe_dir}' && printf '%s\n' '${probe_token}' > '${probe_file}'" \
  || fail "unable to prepare codex probe file"

exec_out="$(mktemp)"
exec_err="$(mktemp)"
trap 'rm -f "${exec_out}" "${exec_err}"' EXIT

set +e
timeout "${exec_timeout}" docker exec "${codex_cid}" sh -lc \
  "cd /workspace && codex -a never -s workspace-write exec --skip-git-repo-check --json --color never '${probe_prompt}'" \
  >"${exec_out}" 2>"${exec_err}"
rc=$?
set -e

if [[ "${rc}" -ne 0 ]]; then
  cat "${exec_out}" >&2 || true
  cat "${exec_err}" >&2 || true
  fail "codex exec tool runtime probe failed (exit=${rc})"
fi

python3 - "${exec_out}" "${probe_token}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
expected = sys.argv[2]

lines = []
for raw in path.read_text(encoding="utf-8").splitlines():
    raw = raw.strip()
    if not raw:
        continue
    lines.append(json.loads(raw))

if not lines:
    raise SystemExit("codex exec emitted no JSON events")

last_message = ""
for entry in lines:
    if entry.get("type") != "item.completed":
        continue
    item = entry.get("item")
    if not isinstance(item, dict):
        continue
    if item.get("type") == "agent_message":
        text = item.get("text")
        if isinstance(text, str):
            last_message = text.strip()

has_command_execution = False
for entry in lines:
    event_type = entry.get("type")
    if event_type not in ("item.started", "item.completed"):
        continue
    item = entry.get("item")
    if not isinstance(item, dict):
        continue
    if item.get("type") == "command_execution":
        has_command_execution = True
        break

if not has_command_execution:
    raise SystemExit("codex exec emitted no command_execution item events (tool execution missing)")
if last_message != expected:
    raise SystemExit(
        f"codex final message does not match probe token: expected={expected!r} got={last_message!r}"
    )
PY

ok "codex exec runtime emits command_execution events and returns exact tool-read token"
ok "L10_codex_exec_tool_runtime passed"
