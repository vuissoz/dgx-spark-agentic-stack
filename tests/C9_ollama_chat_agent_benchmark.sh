#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_C_TESTS:-0}" == "1" ]]; then
  ok "C9 skipped because AGENTIC_SKIP_C_TESTS=1"
  exit 0
fi

assert_cmd python3
assert_cmd curl

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

ollama_cid="$(require_service_container ollama)"
wait_for_container_ready "${ollama_cid}" 180 || fail "ollama is not ready"

benchmark_tmp="$(mktemp -d)"
benchmark_json="${benchmark_tmp}/benchmark.json"
trap 'rm -rf "${benchmark_tmp}"' EXIT

set +e
"${agent_bin}" ollama bench \
  --limit 1 \
  --sort size-asc \
  --output-dir "${benchmark_tmp}/artifacts" \
  --request-timeout-sec "${OLLAMA_BENCH_TEST_TIMEOUT_SECONDS:-900}" \
  --json >"${benchmark_json}" 2>"${benchmark_tmp}/stderr.log"
bench_rc=$?
set -e

if [[ "${bench_rc}" -ne 0 ]]; then
  cat "${benchmark_tmp}/stderr.log" >&2 || true
  cat "${benchmark_json}" >&2 || true
  fail "ollama bench command failed"
fi

python3 - "${benchmark_json}" <<'PY'
import json
import sys
from pathlib import Path

json_path = Path(sys.argv[1])
text = json_path.read_text(encoding="utf-8")
start = text.find("{")
if start < 0:
    raise SystemExit("no JSON payload found in bench output")
payload = json.loads(text[start:])
models = payload.get("models") or []
if len(models) != 1:
    raise SystemExit(f"expected exactly one benchmarked model, got {len(models)}")
model = models[0]
if model.get("status") != "ok":
    raise SystemExit(f"benchmark status is not ok: {model.get('status')} error={model.get('error')}")
hello = model.get("hello") or {}
chapter = model.get("chapter_summary") or {}
required_numeric_fields = [
    ("hello.load_duration_seconds", hello.get("load_duration_seconds")),
    ("hello.tokens_per_second", hello.get("tokens_per_second")),
    ("chapter.prompt_eval_duration_seconds", chapter.get("prompt_eval_duration_seconds")),
    ("chapter.prompt_tokens_per_second", chapter.get("prompt_tokens_per_second")),
    ("chapter.summary_tokens_per_second", chapter.get("summary_tokens_per_second")),
]
for label, value in required_numeric_fields:
    if not isinstance(value, (int, float)):
        raise SystemExit(f"{label} is not numeric: {value!r}")
    if value < 0:
        raise SystemExit(f"{label} is negative: {value!r}")
report_path = None
summary_path = None
for line in text.splitlines():
    if line.startswith("ollama_chat_bench_report="):
        report_path = line.split("=", 1)[1].strip()
    if line.startswith("ollama_chat_bench_summary="):
        summary_path = line.split("=", 1)[1].strip()
if not report_path:
    raise SystemExit("report path marker not found in bench output")
if not summary_path:
    raise SystemExit("summary path marker not found in bench output")
if not Path(report_path).is_file():
    raise SystemExit(f"report path missing: {report_path}")
if not Path(summary_path).is_file():
    raise SystemExit(f"summary path missing: {summary_path}")
PY

ok "ollama bench emitted JSON report and summary artifacts"
ok "C9_ollama_chat_agent_benchmark passed"
