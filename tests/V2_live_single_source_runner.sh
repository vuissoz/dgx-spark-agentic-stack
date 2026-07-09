#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/fake-bin"
host_root="${tmp_dir}/host-root"
mkdir -p "${fake_bin}"

cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "ps" ]]; then
  project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --filter)
        if [[ "${2:-}" == label=com.docker.compose.project=* ]]; then
          project="${2#label=com.docker.compose.project=}"
        fi
        shift 2
        ;;
      --format)
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  if [[ "${project}" == "agentic-live-proof" ]]; then
    printf '%s\n' 'agentic-live-proof-ollama-gate-1|Up 3 minutes'
  fi
  exit 0
fi
echo "unexpected docker args: $*" >&2
exit 9
SH
chmod +x "${fake_bin}/docker"

output_file="${tmp_dir}/live-proof.json"
PATH="${fake_bin}:$PATH" "${REPO_ROOT}/scripts/run_v2_live_single_source_of_truth.py" \
  --agentic-root "${host_root}" \
  --profile rootless-dev \
  --compose-project agentic-live-proof \
  --bootstrap-runtime-target \
  --output "${output_file}" >/tmp/agent-v2-live-runner.out 2>/tmp/agent-v2-live-runner.err

python3 - "${output_file}" "${host_root}" <<'PY'
import json
import pathlib
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
host_root = pathlib.Path(sys.argv[2])
gate = data["gates"]["p0-single-source-of-truth"]
assert gate["status"] == "pass"
assert gate["evidence"]["require_live_stack"] is True
assert gate["evidence"]["domains"]["live_stack"]["status"] == "pass"
assert data["runtime"]["agentic_root"] == str(host_root)
PY
grep -q '^gate_status=pass$' /tmp/agent-v2-live-runner.out \
  || fail "runner must print pass summary"
grep -q '^compose_project=agentic-live-proof$' /tmp/agent-v2-live-runner.out \
  || fail "runner must print compose project summary"
ok "live single-source runner executes host-backed evidence path"

set +e
"${REPO_ROOT}/scripts/run_v2_live_single_source_of_truth.py" \
  --agentic-root "${tmp_dir}/inactive-root" \
  --profile rootless-dev \
  --compose-project agentic-live-proof \
  --bootstrap-runtime-target \
  --output "${tmp_dir}/inactive-live-proof.json" >/tmp/agent-v2-live-runner-fail.out 2>/tmp/agent-v2-live-runner-fail.err
runner_fail_rc=$?
set -e
[[ "${runner_fail_rc}" -ne 0 ]] || fail "runner must fail closed when live stack is absent"
python3 - "${tmp_dir}/inactive-live-proof.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["gates"]["p0-single-source-of-truth"]["status"] == "fail"
PY
ok "live single-source runner fails closed without a live stack"

ok "V2_live_single_source_runner passed"
