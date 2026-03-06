#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L8 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

assert_cmd python3
assert_cmd grep

matrix_json="${REPO_ROOT}/docs/runbooks/ollama-agent-integration-matrix.v1.json"
matrix_doc="${REPO_ROOT}/docs/runbooks/ollama-agent-integration-matrix.md"
agent_bin="${REPO_ROOT}/agent"
fixture_src="${SCRIPT_DIR}/fixtures/ollama-drift"

[[ -f "${matrix_json}" ]] || fail "matrix JSON is missing: ${matrix_json}"
[[ -f "${matrix_doc}" ]] || fail "matrix doc is missing: ${matrix_doc}"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"
[[ -d "${fixture_src}" ]] || fail "fixture directory missing: ${fixture_src}"

python3 - "${matrix_json}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
entries = payload.get("entries") or []
index = {entry.get("agent"): entry for entry in entries if isinstance(entry, dict)}

required = {
    "opencode": "https://raw.githubusercontent.com/ollama/ollama/main/docs/integrations/opencode.mdx",
    "openclaw": "https://raw.githubusercontent.com/ollama/ollama/main/docs/integrations/openclaw.mdx",
}

for agent, upstream_url in required.items():
    entry = index.get(agent)
    if entry is None:
        raise SystemExit(f"missing matrix entry for {agent}")
    if entry.get("upstream_launch_support") != "launch-supported":
        raise SystemExit(f"{agent}: upstream_launch_support must be launch-supported")
    source = entry.get("contract_source") or {}
    if source.get("upstream_doc_url") != upstream_url:
        raise SystemExit(f"{agent}: unexpected upstream_doc_url={source.get('upstream_doc_url')!r}")
    cmds = source.get("upstream_launch_commands") or []
    if not any(cmd.startswith("ollama launch ") for cmd in cmds):
        raise SystemExit(f"{agent}: missing launch command list")
    tests = entry.get("contract_tests") or []
    if "tests/L8_ollama_launch_alignment_contracts.sh" not in tests:
        raise SystemExit(f"{agent}: contract_tests must include L8")
print("matrix launch entries validated")
PY
ok "matrix launch-supported entries are versioned for opencode/openclaw"

suffix="l8-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"

fixture_tmp="$(mktemp -d)"
state_dir="${AGENTIC_ROOT}/deployments/ollama-drift-step7-l8"

cleanup() {
  rm -rf "${fixture_tmp}" >/dev/null 2>&1 || true
  rm -rf "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cp -R "${fixture_src}/." "${fixture_tmp}/"

set +e
"${agent_bin}" ollama-drift watch \
  --no-beads \
  --sources opencode,openclaw \
  --sources-dir "${fixture_tmp}" \
  --state-dir "${state_dir}" >/tmp/agent-l8-run1.out 2>&1
rc1=$?
set -e
[[ "${rc1}" -eq 0 ]] || {
  cat /tmp/agent-l8-run1.out >&2
  fail "launch alignment watch should pass for opencode/openclaw fixtures"
}
grep -q 'no drift detected' /tmp/agent-l8-run1.out || fail "expected explicit no-drift output"
grep -q '\[source:opencode\]' "${state_dir}/latest-report.txt" || fail "report must include source:opencode"
grep -q '\[source:openclaw\]' "${state_dir}/latest-report.txt" || fail "report must include source:openclaw"
ok "launch-supported subset watch passes for opencode/openclaw"

sed -i '/ollama launch openclaw --config/d' "${fixture_tmp}/openclaw.mdx"

set +e
"${agent_bin}" ollama-drift watch \
  --no-beads \
  --sources opencode,openclaw \
  --sources-dir "${fixture_tmp}" \
  --state-dir "${state_dir}" >/tmp/agent-l8-run2.out 2>&1
rc2=$?
set -e
[[ "${rc2}" -eq 2 ]] || {
  cat /tmp/agent-l8-run2.out >&2
  fail "launch alignment watch must fail (exit=2) when openclaw invariant drifts"
}
grep -q 'openclaw:missing:ollama launch openclaw --config' "${state_dir}/latest-report.txt" \
  || fail "drift report must include missing openclaw launch invariant"
ok "launch invariant regression is detected explicitly for openclaw"

ok "L8_ollama_launch_alignment_contracts passed"
