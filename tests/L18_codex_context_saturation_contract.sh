#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  printf 'OK: L18 skipped because AGENTIC_SKIP_L_TESTS=1\n'
  exit 0
fi

command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 1; }
script="${REPO_ROOT}/scripts/codex_context_saturation.py"
[[ -x "${script}" ]] || { echo "ERROR: saturation script is missing or not executable" >&2; exit 1; }

tmp_root="$(mktemp -d)"
port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
server_pid=""
cleanup() {
  [[ -n "${server_pid}" ]] && kill "${server_pid}" >/dev/null 2>&1 || true
  [[ -n "${server_pid}" ]] && wait "${server_pid}" >/dev/null 2>&1 || true
  rm -rf "${tmp_root}"
}
trap cleanup EXIT

fixture_dir="${tmp_root}/fixture"
mkdir -p "${fixture_dir}"
printf 'Premier roman. %s\n' "$(printf 'mot %.0s' {1..80})" > "${fixture_dir}/book-one.txt"
printf 'Second roman. %s\n' "$(printf 'mot %.0s' {1..80})" > "${fixture_dir}/book-two.txt"
python3 -m http.server "${port}" --bind 127.0.0.1 --directory "${fixture_dir}" >"${tmp_root}/http.log" 2>&1 &
server_pid=$!

manifest="${tmp_root}/manifest.json"
cat >"${manifest}" <<JSON
[
  {"id":"book-one","title":"Livre un","author":"Jules Verne","url":"http://127.0.0.1:${port}/book-one.txt"},
  {"id":"book-two","title":"Livre deux","author":"Jules Verne","url":"http://127.0.0.1:${port}/book-two.txt"}
]
JSON

output_dir="${tmp_root}/artifacts"
python3 "${script}" \
  --codex-container unused-in-dry-run \
  --output-dir "${output_dir}" \
  --corpus-manifest "${manifest}" \
  --context-window 1000 \
  --target-percent 70 \
  --hard-stop-percent 90 \
  --max-chars-per-load-turn 10000 \
  --dry-run --json >"${tmp_root}/stdout.json"

python3 - "${tmp_root}/stdout.json" "${output_dir}" <<'PY'
import json
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
payload = json.loads(text[text.find("{"):])
output_dir = pathlib.Path(sys.argv[2])
assert payload["status"] == "target-reachable"
assert payload["dry_run"] is True
assert payload["target_percent"] == 70.0
assert payload["hard_stop_percent"] == 90.0
assert payload["planned_turns"]
assert payload["peak_fill_percent"] >= 70
assert payload["peak_fill_percent"] < 90
assert (output_dir / "codex-context-saturation.json").is_file()
assert (output_dir / "codex-context-saturation.md").is_file()
assert "Dernier tour accepté" in (output_dir / "codex-context-saturation.md").read_text()
PY

printf 'OK: L18 controlled saturation dry-run contract passed\n'
