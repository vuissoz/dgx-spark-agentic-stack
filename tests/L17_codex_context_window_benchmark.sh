#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L17 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd python3
assert_cmd curl
assert_cmd timeout

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

if [[ -z "${AGENTIC_ROOT:-}" || -z "${AGENTIC_COMPOSE_PROJECT:-}" ]]; then
  runtime_env="${HOME}/.local/share/agentic/deployments/runtime.env"
  if [[ ! -f "${runtime_env}" ]]; then
    runtime_env="/srv/agentic/deployments/runtime.env"
  fi
  [[ -f "${runtime_env}" ]] || fail "runtime env file not found: ${runtime_env}"
  set -a
  # shellcheck disable=SC1090
  source "${runtime_env}"
  set +a
fi

codex_cid="$(require_service_container agentic-codex)" || exit 1
wait_for_container_ready "${codex_cid}" 120 || fail "agentic-codex is not ready"

fixture_dir="${REPO_ROOT}/tests/fixtures/codex-context-bench"
[[ -d "${fixture_dir}" ]] || fail "fixture directory missing: ${fixture_dir}"

tmp_root="$(mktemp -d)"
manifest_path="${tmp_root}/manifest.json"
stdout_path="${tmp_root}/stdout.log"
stderr_path="${tmp_root}/stderr.log"
output_dir="${tmp_root}/artifacts"
port="$(pick_free_loopback_port 24170 200)"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${tmp_root}"
}
trap cleanup EXIT

cat >"${manifest_path}" <<JSON
[
  {"id":"vingt-mille-lieues-sous-les-mers","title":"Vingt mille lieues sous les mers","author":"Jules Verne","url":"http://127.0.0.1:${port}/01-vingt-mille-lieues.txt"},
  {"id":"ile-mysterieuse","title":"L'ile mysterieuse","author":"Jules Verne","url":"http://127.0.0.1:${port}/02-ile-mysterieuse.txt"},
  {"id":"voyage-au-centre-de-la-terre","title":"Voyage au centre de la Terre","author":"Jules Verne","url":"http://127.0.0.1:${port}/03-voyage-centre-terre.txt"},
  {"id":"de-la-terre-a-la-lune","title":"De la Terre a la Lune","author":"Jules Verne","url":"http://127.0.0.1:${port}/04-terre-lune.txt"}
]
JSON

(cd "${fixture_dir}" && python3 -m http.server "${port}" --bind 127.0.0.1 >"${tmp_root}/http.log" 2>&1) &
server_pid=$!

timeout 30 sh -lc "until curl -fsS http://127.0.0.1:${port}/01-vingt-mille-lieues.txt >/dev/null; do sleep 1; done" \
  || fail "fixture HTTP server did not start"

set +e
"${agent_bin}" codex bench-context \
  --corpus-manifest "${manifest_path}" \
  --output-dir "${output_dir}" \
  --request-timeout-sec "${AGENTIC_CODEX_CONTEXT_BENCH_TEST_TIMEOUT_SECONDS:-900}" \
  --download-timeout-sec 30 \
  --json >"${stdout_path}" 2>"${stderr_path}"
rc=$?
set -e

if [[ "${rc}" -ne 0 ]]; then
  cat "${stdout_path}" >&2 || true
  cat "${stderr_path}" >&2 || true
  fail "agent codex bench-context failed"
fi

python3 - "${stdout_path}" <<'PY'
import json
import sys
from pathlib import Path

stdout_path = Path(sys.argv[1])
text = stdout_path.read_text(encoding="utf-8")
lines = [line.strip() for line in text.splitlines() if line.strip()]
report_path = None
json_path = None
thread_id = None
for line in lines:
    if line.startswith("codex_context_bench_report="):
        report_path = Path(line.split("=", 1)[1].strip())
    if line.startswith("codex_context_bench_json="):
        json_path = Path(line.split("=", 1)[1].strip())
    if line.startswith("codex_context_bench_thread_id="):
        thread_id = line.split("=", 1)[1].strip()
if report_path is None or not report_path.is_file():
    raise SystemExit("missing markdown report artifact")
if json_path is None or not json_path.is_file():
    raise SystemExit("missing JSON report artifact")
if not thread_id:
    raise SystemExit("missing codex thread id marker")

start = text.find("{")
if start < 0:
    raise SystemExit("no JSON payload emitted")
payload = json.loads(text[start:])
books = payload.get("books") or []
if len(books) != 4:
    raise SystemExit(f"expected 4 books, got {len(books)}")
if payload.get("codex_thread_id") != thread_id:
    raise SystemExit("thread id marker mismatch")

previous_tokens = -1
for book in books:
    summary = (book.get("summary") or "").strip()
    if not summary:
        raise SystemExit(f"missing summary for {book.get('id')}")
    summary_turn = book.get("summary_turn") or {}
    input_tokens = summary_turn.get("input_tokens")
    if not isinstance(input_tokens, int) or input_tokens <= 0:
        raise SystemExit(f"invalid input token count for {book.get('id')}: {input_tokens!r}")
    if input_tokens <= previous_tokens:
        raise SystemExit("summary input_tokens must grow across resumed turns")
    previous_tokens = input_tokens
    fill = summary_turn.get("context_fill_percent")
    if fill is not None and not isinstance(fill, (int, float)):
        raise SystemExit(f"invalid fill percent for {book.get('id')}: {fill!r}")

final_summary = payload.get("final_summary") or {}
final_text = (final_summary.get("summary") or "").strip()
if not final_text:
    raise SystemExit("missing final summary text")
final_tokens = final_summary.get("input_tokens")
if not isinstance(final_tokens, int) or final_tokens <= previous_tokens:
    raise SystemExit("final summary input_tokens must exceed the last per-book summary")

report_text = report_path.read_text(encoding="utf-8")
for title in (
    "Vingt mille lieues sous les mers",
    "L'ile mysterieuse",
    "Voyage au centre de la Terre",
    "De la Terre a la Lune",
):
    if title not in report_text:
        raise SystemExit(f"title missing from markdown report: {title}")
if "## Synthese finale" not in report_text:
    raise SystemExit("markdown report missing final synthesis section")
PY

ok "codex bench-context produced report artifacts and monotonically growing context usage"
ok "L17_codex_context_window_benchmark passed"
