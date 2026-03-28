#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F12 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

tmpdir="$(mktemp -d)"
bindir="${tmpdir}/bin"
runtime_root="${tmpdir}/runtime"
state_file="${tmpdir}/loaded-models.txt"
stop_log="${tmpdir}/stop.log"
mkdir -p "${bindir}" "${runtime_root}"

cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

cat >"${bindir}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_file="${MOCK_OLLAMA_STATE_FILE:?}"
stop_log="${MOCK_OLLAMA_STOP_LOG:?}"
running="${MOCK_OLLAMA_RUNNING:-1}"
cid="mock-ollama-cid"

case "${1:-}" in
  ps)
    if [[ "${running}" == "1" ]]; then
      printf '%s\n' "${cid}"
    fi
    exit 0
    ;;
  exec)
    exec_cid="${2:-}"
    shift 2
    [[ "${exec_cid}" == "${cid}" ]] || {
      echo "unexpected container id: ${exec_cid}" >&2
      exit 1
    }

    if [[ "${1:-}" == "ollama" && "${2:-}" == "ps" ]]; then
      printf 'NAME\tID\tSIZE\tPROCESSOR\tUNTIL\n'
      if [[ -f "${state_file}" ]]; then
        while IFS= read -r model || [[ -n "${model}" ]]; do
          [[ -n "${model}" ]] || continue
          printf '%s\tid\t1 GB\t100%% GPU\t4 minutes from now\n' "${model}"
        done < "${state_file}"
      fi
      exit 0
    fi

    if [[ "${1:-}" == "ollama" && "${2:-}" == "stop" ]]; then
      model="${3:-}"
      grep -Fxq "${model}" "${state_file}" || {
        printf 'model not loaded: %s\n' "${model}" >&2
        exit 1
      }
      printf '%s\n' "${model}" >>"${stop_log}"
      grep -Fxv "${model}" "${state_file}" >"${state_file}.tmp" || true
      mv "${state_file}.tmp" "${state_file}"
      printf 'stopped %s\n' "${model}"
      exit 0
    fi
    ;;
esac

echo "unexpected docker invocation: $*" >&2
exit 1
EOF

chmod 0755 "${bindir}/docker"

run_agent() {
  PATH="${bindir}:${PATH}" \
  AGENTIC_PROFILE=rootless-dev \
  AGENTIC_ROOT="${runtime_root}" \
  AGENTIC_AGENT_WORKSPACES_ROOT="${runtime_root}/agent-workspaces" \
  MOCK_OLLAMA_STATE_FILE="${state_file}" \
  MOCK_OLLAMA_STOP_LOG="${stop_log}" \
    "${agent_bin}" "$@"
}

printf '%s\n' 'qwen3-coder:30b' >"${state_file}"
: >"${stop_log}"

run_agent ollama unload qwen3-coder:30b >"${tmpdir}/unload.out"
grep -q 'result=unloaded' "${tmpdir}/unload.out" \
  || fail "ollama unload must report result=unloaded when the model was loaded"
grep -Fxq 'qwen3-coder:30b' "${stop_log}" \
  || fail "ollama unload must invoke ollama stop for a loaded model"
if grep -Fxq 'qwen3-coder:30b' "${state_file}"; then
  fail "ollama unload must remove the model from the loaded set"
fi
changes_log="${runtime_root}/deployments/changes.log"
grep -q 'model=qwen3-coder:30b' "${changes_log}" \
  || fail "ollama unload must log the model name in changes.log"
grep -q 'result=unloaded' "${changes_log}" \
  || fail "ollama unload must log result=unloaded"
ok "ollama unload unloads a loaded model and records the action"

: >"${state_file}"
: >"${stop_log}"

run_agent ollama unload qwen3-coder:30b >"${tmpdir}/already-unloaded.out"
grep -q 'result=already-unloaded' "${tmpdir}/already-unloaded.out" \
  || fail "ollama unload must be idempotent when the model is already unloaded"
[[ ! -s "${stop_log}" ]] \
  || fail "ollama unload must not call ollama stop when the model is already unloaded"
grep -q 'result=already-unloaded' "${changes_log}" \
  || fail "ollama unload must log result=already-unloaded"
ok "ollama unload is idempotent when the model is not loaded"

set +e
PATH="${bindir}:${PATH}" \
AGENTIC_PROFILE=rootless-dev \
AGENTIC_ROOT="${runtime_root}" \
AGENTIC_AGENT_WORKSPACES_ROOT="${runtime_root}/agent-workspaces" \
MOCK_OLLAMA_STATE_FILE="${state_file}" \
MOCK_OLLAMA_STOP_LOG="${stop_log}" \
MOCK_OLLAMA_RUNNING=0 \
  "${agent_bin}" ollama unload qwen3-coder:30b >"${tmpdir}/backend-down.out" 2>&1
backend_down_rc=$?
set -e
[[ "${backend_down_rc}" -ne 0 ]] || fail "ollama unload must fail when the Ollama backend is not running"
grep -q 'Ollama backend is not running' "${tmpdir}/backend-down.out" \
  || fail "ollama unload backend-down error must be explicit"
ok "ollama unload fails closed when the Ollama backend is unavailable"

ok "F12_ollama_unload_command passed"
