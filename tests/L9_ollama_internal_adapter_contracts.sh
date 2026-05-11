#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L9 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

assert_cmd python3
assert_cmd rg

matrix_json="${REPO_ROOT}/docs/runbooks/ollama-agent-integration-matrix.v1.json"
compose_ui="${REPO_ROOT}/compose/compose.ui.yml"
entrypoint="${REPO_ROOT}/deployments/images/agent-cli-base/entrypoint.sh"
onboarding="${REPO_ROOT}/deployments/bootstrap/onboarding_env.sh"

[[ -f "${matrix_json}" ]] || fail "matrix JSON is missing: ${matrix_json}"
[[ -f "${compose_ui}" ]] || fail "compose file missing: ${compose_ui}"
[[ -f "${entrypoint}" ]] || fail "entrypoint file missing: ${entrypoint}"
[[ -f "${onboarding}" ]] || fail "onboarding file missing: ${onboarding}"

python3 - "${matrix_json}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
entries = payload.get("entries") or []
index = {entry.get("agent"): entry for entry in entries if isinstance(entry, dict)}

checks = {
    "openhands": {
        "support": "adapter-internal",
        "endpoint": "http://ollama-gate:11435/v1",
        "vars": {"LLM_BASE_URL", "LLM_MODEL", "LLM_API_KEY"},
    },
    "vibestral": {
        "support": "adapter-internal",
        "endpoint": "http://ollama-gate:11435/v1",
        "vars": {"AGENTIC_OLLAMA_GATE_V1_URL", "AGENTIC_DEFAULT_MODEL"},
    },
    "hermes": {
        "support": "launch-supported",
        "endpoint": "http://ollama-gate:11435/v1",
        "vars": {"HERMES_HOME", "OPENAI_API_KEY", "AGENTIC_DEFAULT_MODEL", "AGENTIC_OLLAMA_GATE_V1_URL"},
        "upstream_doc_url": "https://raw.githubusercontent.com/ollama/ollama/main/docs/integrations/hermes.mdx",
    },
}

for agent, expected in checks.items():
    entry = index.get(agent)
    if entry is None:
        raise SystemExit(f"missing matrix entry for {agent}")
    if entry.get("upstream_launch_support") != expected["support"]:
        raise SystemExit(f"{agent}: unexpected upstream_launch_support={entry.get('upstream_launch_support')!r}")
    if entry.get("target_endpoint") != expected["endpoint"]:
        raise SystemExit(f"{agent}: unexpected target_endpoint={entry.get('target_endpoint')!r}")
    source = entry.get("contract_source") or {}
    if "upstream_doc_url" in expected and source.get("upstream_doc_url") != expected["upstream_doc_url"]:
        raise SystemExit(f"{agent}: unexpected upstream_doc_url={source.get('upstream_doc_url')!r}")
    vars_declared = set(entry.get("required_variables") or [])
    if not expected["vars"].issubset(vars_declared):
        raise SystemExit(f"{agent}: required variables missing (expected subset {sorted(expected['vars'])}, got {sorted(vars_declared)})")
    tests = entry.get("contract_tests") or []
    if "tests/L9_ollama_internal_adapter_contracts.sh" not in tests:
        raise SystemExit(f"{agent}: contract_tests must include L9")
print("matrix managed adapter entries validated")
PY
ok "matrix managed entries are versioned for openhands/vibestral/hermes"

rg -n '^[[:space:]]*LLM_BASE_URL:[[:space:]]*http://ollama-gate:11435/v1[[:space:]]*$' "${compose_ui}" >/dev/null \
  || fail "compose.ui must pin openhands LLM_BASE_URL to ollama-gate /v1"
rg -n '^[[:space:]]*OH_SANDBOX_KIND:[[:space:]]*ProcessSandboxServiceInjector[[:space:]]*$' "${compose_ui}" >/dev/null \
  || fail "compose.ui must keep openhands ProcessSandboxServiceInjector adapter"
rg -n '^[[:space:]]*OH_SANDBOX_SPEC_KIND:[[:space:]]*ProcessSandboxSpecServiceInjector[[:space:]]*$' "${compose_ui}" >/dev/null \
  || fail "compose.ui must keep openhands ProcessSandboxSpecServiceInjector adapter"
ok "openhands adapter contract is pinned in compose.ui"

rg -nF 'bootstrap_vibestral_config() {' "${entrypoint}" >/dev/null \
  || fail "entrypoint must define vibestral bootstrap adapter"
rg -nF 'api_base = "${AGENTIC_OLLAMA_GATE_V1_URL:-http://ollama-gate:11435/v1}"' "${entrypoint}" >/dev/null \
  || fail "vibestral adapter must target AGENTIC_OLLAMA_GATE_V1_URL default"
rg -n '^api_key_env_var = \"OPENAI_API_KEY\"$' "${entrypoint}" >/dev/null \
  || fail "vibestral adapter must route API key through OPENAI_API_KEY env"
rg -n '^active_model = \"local-gate\"$' "${entrypoint}" >/dev/null \
  || fail "vibestral adapter must force local-gate profile"
ok "vibestral adapter contract is pinned in entrypoint"

rg -nF 'bootstrap_hermes_config() {' "${entrypoint}" >/dev/null \
  || fail "entrypoint must define hermes bootstrap adapter"
rg -n '^  provider: custom$' "${entrypoint}" >/dev/null \
  || fail "hermes adapter must use the custom OpenAI-compatible provider"
rg -nF 'local gate_v1_url="${AGENTIC_OLLAMA_GATE_V1_URL:-http://ollama-gate:11435/v1}"' "${entrypoint}" >/dev/null \
  || fail "hermes adapter must derive gate_v1_url from AGENTIC_OLLAMA_GATE_V1_URL default"
rg -n '^  - web$' "${entrypoint}" >/dev/null \
  || fail "hermes adapter must enable the web toolset for launch parity"
! rg -n '^  api_key:' "${entrypoint}" >/dev/null \
  || fail "hermes adapter must not persist API keys in config.yaml"
! rg -nF 'OPENAI_BASE_URL=${gate_v1_url}' "${entrypoint}" >/dev/null \
  || fail "hermes adapter must not persist OPENAI_BASE_URL in managed .env"
ok "hermes launch-compatible adapter contract is pinned in entrypoint"

rg -nF 'bootstrap_kilocode_config() {' "${entrypoint}" >/dev/null \
  || fail "entrypoint must define kilocode bootstrap adapter"
rg -nF 'local kilocode_config="${agent_home}/.config/kilo/opencode.json"' "${entrypoint}" >/dev/null \
  || fail "kilocode adapter must target ~/.config/kilo/opencode.json"
rg -nF 'base["$schema"] = "https://app.kilo.ai/config.json"' "${entrypoint}" >/dev/null \
  || fail "kilocode adapter must set the Kilo config schema"
ok "kilocode adapter contract is pinned in entrypoint"

rg -n '^openhands_llm_base_url=\"http://ollama-gate:11435/v1\"$' "${onboarding}" >/dev/null \
  || fail "onboarding must default openhands llm_base_url to ollama-gate /v1"
ok "onboarding contract keeps openhands default LLM endpoint on gate"

if command -v docker >/dev/null 2>&1; then
  openhands_cid="$(service_container_id openhands || true)"
  if [[ -n "${openhands_cid}" ]]; then
    wait_for_container_ready "${openhands_cid}" 120 || fail "openhands container is not ready"
    docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${openhands_cid}" \
      | grep -q '^LLM_BASE_URL=http://ollama-gate:11435/v1$' \
      || fail "running openhands container must keep LLM_BASE_URL on ollama-gate /v1"
    ok "running openhands container keeps adapter endpoint contract"
  else
    warn "openhands container not running; runtime adapter assertion skipped"
  fi

  kilocode_cid="$(service_container_id agentic-kilocode || true)"
  if [[ -n "${kilocode_cid}" ]]; then
    wait_for_container_ready "${kilocode_cid}" 120 || fail "agentic-kilocode container is not ready"
    kilocode_default_model="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${kilocode_cid}" \
      | awk -F= '$1=="AGENTIC_DEFAULT_MODEL"{print substr($0, index($0, "=")+1); exit}')"
    [[ -n "${kilocode_default_model}" ]] || fail "agentic-kilocode env is missing AGENTIC_DEFAULT_MODEL"
    kilocode_cfg="$(mktemp)"
    docker exec "${kilocode_cid}" sh -lc 'cat /state/home/.config/kilo/opencode.json' >"${kilocode_cfg}" \
      || fail "unable to read kilocode runtime config"
    python3 - "${kilocode_cfg}" "${kilocode_default_model}" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
model = sys.argv[2]

assert payload.get("$schema") == "https://app.kilo.ai/config.json"
assert payload.get("model") == f"ollama/{model}"
provider = (payload.get("provider") or {}).get("ollama") or {}
assert (provider.get("options") or {}).get("baseURL") == "http://ollama-gate:11435/v1"
assert model in (provider.get("models") or {})
PY
    rm -f "${kilocode_cfg}" >/dev/null 2>&1 || true
    ok "running kilocode container keeps adapter endpoint contract"
  else
    warn "agentic-kilocode container not running; runtime adapter assertion skipped"
  fi

  vibestral_cid="$(service_container_id agentic-vibestral || true)"
  if [[ -n "${vibestral_cid}" ]]; then
    wait_for_container_ready "${vibestral_cid}" 120 || fail "agentic-vibestral container is not ready"
    vibestral_default_model="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${vibestral_cid}" \
      | awk -F= '$1=="AGENTIC_DEFAULT_MODEL"{print substr($0, index($0, "=")+1); exit}')"
    [[ -n "${vibestral_default_model}" ]] || fail "agentic-vibestral env is missing AGENTIC_DEFAULT_MODEL"
    vibestral_cfg="$(mktemp)"
    docker exec "${vibestral_cid}" sh -lc 'cat /state/home/.vibe/config.toml' >"${vibestral_cfg}" \
      || fail "unable to read vibestral runtime config"
    grep -q '^name = "ollama-gate"$' "${vibestral_cfg}" \
      || fail "vibestral runtime config must define provider ollama-gate"
    grep -q '^api_base = "http://ollama-gate:11435/v1"$' "${vibestral_cfg}" \
      || fail "vibestral runtime config must target ollama-gate /v1"
    grep -q '^api_key_env_var = "OPENAI_API_KEY"$' "${vibestral_cfg}" \
      || fail "vibestral runtime config must use OPENAI_API_KEY for local gate auth"
    grep -q "^name = \"${vibestral_default_model}\"$" "${vibestral_cfg}" \
      || fail "vibestral runtime config model must match AGENTIC_DEFAULT_MODEL (${vibestral_default_model})"
    rm -f "${vibestral_cfg}" >/dev/null 2>&1 || true
    docker exec "${vibestral_cid}" sh -lc '
      set -e
      set -a
      . /state/bootstrap/ollama-gate-defaults.env
      set +a
      out="$(mktemp)"
      err="$(mktemp)"
      timeout 60 vibe -p "Return exactly OK." --output json --workdir /workspace --max-turns 2 >"${out}" 2>"${err}"
      grep -q "\"content\": \"OK\"" "${out}"
      test ! -s "${err}"
    ' || fail "vibestral programmatic mode must work once bootstrap defaults are sourced"
    ok "running vibestral container keeps adapter endpoint contract"
  else
    warn "agentic-vibestral container not running; runtime adapter assertion skipped"
  fi

  hermes_cid="$(service_container_id agentic-hermes || true)"
  if [[ -n "${hermes_cid}" ]]; then
    wait_for_container_ready "${hermes_cid}" 120 || fail "agentic-hermes container is not ready"
    hermes_default_model="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${hermes_cid}" \
      | awk -F= '$1=="AGENTIC_DEFAULT_MODEL"{print substr($0, index($0, "=")+1); exit}')"
    [[ -n "${hermes_default_model}" ]] || fail "agentic-hermes env is missing AGENTIC_DEFAULT_MODEL"
    hermes_cfg="$(mktemp)"
    hermes_env="$(mktemp)"
    docker exec "${hermes_cid}" sh -lc 'cat /state/home/.hermes/config.yaml' >"${hermes_cfg}" \
      || fail "unable to read hermes runtime config"
    docker exec "${hermes_cid}" sh -lc 'cat /state/home/.hermes/.env' >"${hermes_env}" \
      || fail "unable to read hermes runtime env file"
    grep -q '^  provider: custom$' "${hermes_cfg}" \
      || fail "hermes runtime config must set provider=custom"
    grep -q '^  base_url: "http://ollama-gate:11435/v1"$' "${hermes_cfg}" \
      || fail "hermes runtime config must target ollama-gate /v1"
    grep -q "^  default: \"${hermes_default_model}\"$" "${hermes_cfg}" \
      || fail "hermes runtime config model must match AGENTIC_DEFAULT_MODEL (${hermes_default_model})"
    grep -q '^  - web$' "${hermes_cfg}" \
      || fail "hermes runtime config must enable the web toolset"
    ! grep -q '^  api_key:' "${hermes_cfg}" \
      || fail "hermes runtime config must not store API keys in config.yaml"
    grep -q '^OPENAI_API_KEY=local-ollama$' "${hermes_env}" \
      || fail "hermes runtime env must persist local gate API key placeholder"
    ! grep -q '^OPENAI_BASE_URL=' "${hermes_env}" \
      || fail "hermes runtime env must not persist OPENAI_BASE_URL when config.yaml already pins base_url"
    rm -f "${hermes_cfg}" "${hermes_env}" >/dev/null 2>&1 || true
    timeout 60 docker exec "${hermes_cid}" sh -lc 'hermes config path >/dev/null' \
      || fail "hermes CLI must resolve its config path in the managed runtime"
    ok "running hermes container keeps adapter endpoint contract"
  else
    warn "agentic-hermes container not running; runtime adapter assertion skipped"
  fi
else
  warn "docker not available; runtime adapter assertions skipped"
fi

ok "L9_ollama_internal_adapter_contracts passed"
