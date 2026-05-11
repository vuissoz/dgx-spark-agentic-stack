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
entrypoint="${REPO_ROOT}/deployments/images/agent-cli-base/entrypoint.sh"

[[ -f "${matrix_json}" ]] || fail "matrix JSON is missing: ${matrix_json}"
[[ -f "${matrix_doc}" ]] || fail "matrix doc is missing: ${matrix_doc}"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"
[[ -d "${fixture_src}" ]] || fail "fixture directory missing: ${fixture_src}"
[[ -f "${entrypoint}" ]] || fail "entrypoint file missing: ${entrypoint}"

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
    "hermes": "https://raw.githubusercontent.com/ollama/ollama/main/docs/integrations/hermes.mdx",
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
ok "matrix launch-supported entries are versioned for opencode/openclaw/hermes"

rg -nF 'bootstrap_opencode_config() {' "${entrypoint}" >/dev/null \
  || fail "entrypoint must define opencode bootstrap adapter"
rg -nF 'base["model"] = f"ollama/{default_model}"' "${entrypoint}" >/dev/null \
  || fail "opencode bootstrap must map model to local ollama provider"
rg -nF 'base["small_model"] = f"ollama/{default_model}"' "${entrypoint}" >/dev/null \
  || fail "opencode bootstrap must keep small_model on local ollama provider"
rg -nF 'options["baseURL"] = gate_v1_url' "${entrypoint}" >/dev/null \
  || fail "opencode bootstrap must pin provider baseURL to gate v1 endpoint"
ok "opencode bootstrap contract is pinned in entrypoint"

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
  --sources opencode,openclaw,hermes \
  --sources-dir "${fixture_tmp}" \
  --state-dir "${state_dir}" >/tmp/agent-l8-run1.out 2>&1
rc1=$?
set -e
[[ "${rc1}" -eq 0 ]] || {
  cat /tmp/agent-l8-run1.out >&2
  fail "launch alignment watch should pass for opencode/openclaw/hermes fixtures"
}
grep -q 'no drift detected' /tmp/agent-l8-run1.out || fail "expected explicit no-drift output"
grep -q '\[source:opencode\]' "${state_dir}/latest-report.txt" || fail "report must include source:opencode"
grep -q '\[source:openclaw\]' "${state_dir}/latest-report.txt" || fail "report must include source:openclaw"
grep -q '\[source:hermes\]' "${state_dir}/latest-report.txt" || fail "report must include source:hermes"
ok "launch-supported subset watch passes for opencode/openclaw/hermes"

sed -i '/hermes gateway setup/d' "${fixture_tmp}/hermes.mdx"

set +e
"${agent_bin}" ollama-drift watch \
  --no-beads \
  --sources opencode,openclaw,hermes \
  --sources-dir "${fixture_tmp}" \
  --state-dir "${state_dir}" >/tmp/agent-l8-run2.out 2>&1
rc2=$?
set -e
[[ "${rc2}" -eq 2 ]] || {
  cat /tmp/agent-l8-run2.out >&2
  fail "launch alignment watch must fail (exit=2) when hermes invariant drifts"
}
grep -q 'hermes:missing:hermes gateway setup' "${state_dir}/latest-report.txt" \
  || fail "drift report must include missing hermes launch invariant"
ok "launch invariant regression is detected explicitly for hermes"

if command -v docker >/dev/null 2>&1; then
  opencode_cid="$(service_container_id agentic-opencode || true)"
  if [[ -n "${opencode_cid}" ]]; then
    wait_for_container_ready "${opencode_cid}" 120 || fail "agentic-opencode container is not ready"
    opencode_default_model="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${opencode_cid}" \
      | awk -F= '$1=="AGENTIC_DEFAULT_MODEL"{print substr($0, index($0, "=")+1); exit}')"
    [[ -n "${opencode_default_model}" ]] || fail "agentic-opencode env is missing AGENTIC_DEFAULT_MODEL"
    opencode_gate_v1="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${opencode_cid}" \
      | awk -F= '$1=="AGENTIC_OLLAMA_GATE_V1_URL"{print substr($0, index($0, "=")+1); exit}')"
    [[ -n "${opencode_gate_v1}" ]] || opencode_gate_v1="http://ollama-gate:11435/v1"

    opencode_cfg="$(mktemp)"
    docker exec "${opencode_cid}" sh -lc 'cat /state/home/.config/opencode/opencode.json' >"${opencode_cfg}" \
      || fail "unable to read opencode runtime config"
    python3 - "${opencode_cfg}" "${opencode_default_model}" "${opencode_gate_v1}" <<'PY'
import json
import pathlib
import sys

cfg_path = pathlib.Path(sys.argv[1])
default_model = sys.argv[2]
expected_v1 = sys.argv[3]

payload = json.loads(cfg_path.read_text(encoding="utf-8"))
model = payload.get("model")
small_model = payload.get("small_model")
if model != f"ollama/{default_model}":
    raise SystemExit(f"unexpected opencode model={model!r}")
if small_model != f"ollama/{default_model}":
    raise SystemExit(f"unexpected opencode small_model={small_model!r}")

providers = payload.get("provider")
if not isinstance(providers, dict):
    raise SystemExit("missing provider object")
ollama = providers.get("ollama")
if not isinstance(ollama, dict):
    raise SystemExit("missing provider.ollama object")
options = ollama.get("options")
if not isinstance(options, dict):
    raise SystemExit("missing provider.ollama.options object")
if options.get("baseURL") != expected_v1:
    raise SystemExit(f"unexpected provider.ollama.options.baseURL={options.get('baseURL')!r}")
models = ollama.get("models")
if not isinstance(models, dict):
    raise SystemExit("missing provider.ollama.models object")
if default_model not in models:
    raise SystemExit(f"default model key not present in provider.ollama.models ({default_model!r})")
PY
    rm -f "${opencode_cfg}" >/dev/null 2>&1 || true
    ok "running opencode container keeps local default model bootstrap contract"
  else
    warn "agentic-opencode container not running; runtime opencode config assertion skipped"
  fi

  kilocode_cid="$(service_container_id agentic-kilocode || true)"
  if [[ -n "${kilocode_cid}" ]]; then
    wait_for_container_ready "${kilocode_cid}" 120 || fail "agentic-kilocode container is not ready"
    kilocode_default_model="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${kilocode_cid}" \
      | awk -F= '$1=="AGENTIC_DEFAULT_MODEL"{print substr($0, index($0, "=")+1); exit}')"
    [[ -n "${kilocode_default_model}" ]] || fail "agentic-kilocode env is missing AGENTIC_DEFAULT_MODEL"
    kilocode_gate_v1="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${kilocode_cid}" \
      | awk -F= '$1=="AGENTIC_OLLAMA_GATE_V1_URL"{print substr($0, index($0, "=")+1); exit}')"
    [[ -n "${kilocode_gate_v1}" ]] || kilocode_gate_v1="http://ollama-gate:11435/v1"

    kilocode_cfg="$(mktemp)"
    docker exec "${kilocode_cid}" sh -lc 'cat /state/home/.config/kilo/opencode.json' >"${kilocode_cfg}" \
      || fail "unable to read kilocode runtime config"
    python3 - "${kilocode_cfg}" "${kilocode_default_model}" "${kilocode_gate_v1}" <<'PY'
import json
import pathlib
import sys

cfg_path = pathlib.Path(sys.argv[1])
default_model = sys.argv[2]
expected_v1 = sys.argv[3]

payload = json.loads(cfg_path.read_text(encoding="utf-8"))
model = payload.get("model")
small_model = payload.get("small_model")
if model != f"ollama/{default_model}":
    raise SystemExit(f"unexpected kilocode model={model!r}")
if small_model != f"ollama/{default_model}":
    raise SystemExit(f"unexpected kilocode small_model={small_model!r}")
if payload.get("$schema") != "https://app.kilo.ai/config.json":
    raise SystemExit(f"unexpected kilocode schema={payload.get('$schema')!r}")

providers = payload.get("provider")
if not isinstance(providers, dict):
    raise SystemExit("missing provider object")
ollama = providers.get("ollama")
if not isinstance(ollama, dict):
    raise SystemExit("missing provider.ollama object")
options = ollama.get("options")
if not isinstance(options, dict):
    raise SystemExit("missing provider.ollama.options object")
if options.get("baseURL") != expected_v1:
    raise SystemExit(f"unexpected provider.ollama.options.baseURL={options.get('baseURL')!r}")
models = ollama.get("models")
if not isinstance(models, dict):
    raise SystemExit("missing provider.ollama.models object")
if default_model not in models:
    raise SystemExit(f"default model key not present in provider.ollama.models ({default_model!r})")
PY
    rm -f "${kilocode_cfg}" >/dev/null 2>&1 || true
    ok "running kilocode container keeps local default model bootstrap contract"
  else
    warn "agentic-kilocode container not running; runtime kilocode config assertion skipped"
  fi
else
  warn "docker not available; runtime opencode/kilocode config assertions skipped"
fi

ok "L8_ollama_launch_alignment_contracts passed"
