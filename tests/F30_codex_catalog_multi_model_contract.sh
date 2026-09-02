#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd docker

entrypoint="${REPO_ROOT}/deployments/images/agent-cli-base/entrypoint.sh"
compose_file="${REPO_ROOT}/compose/compose.agents.yml"

rg -qF 'AGENTIC_CODEX_CATALOG_MODELS' "${entrypoint}" \
  || fail "Codex entrypoint must support explicit catalog model seeds"
rg -qF '"${gate_base_url}/v1/models"' "${entrypoint}" \
  || fail "Codex entrypoint must discover models through ollama-gate, not a direct backend"
rg -qF '"models": [metadata(slug) for slug in models]' "${entrypoint}" \
  || fail "Codex catalog must render metadata for every selected model"
rg -qF 'AGENTIC_CODEX_CATALOG_MODELS: ${AGENTIC_CODEX_CATALOG_MODELS:-qwen3.5:35b}' "${compose_file}" \
  || fail "agentic-codex must receive the catalog seed"

bash -n "${entrypoint}" || fail "agent entrypoint must remain valid shell"

tmp_dir="$(mktemp -d)"
cleanup() {
  docker run --rm -v "${tmp_dir}":/cleanup alpine:3.21 \
    sh -c 'rm -rf /cleanup/* /cleanup/.[!.]* /cleanup/..?*' >/dev/null 2>&1 || true
  rmdir "${tmp_dir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
mkdir -p "${tmp_dir}/state" "${tmp_dir}/logs" "${tmp_dir}/workspace"

docker run --rm --user 0:0 \
  -e AGENT_TOOL=codex \
  -e AGENT_STATE_DIR=/state \
  -e AGENT_LOGS_DIR=/logs \
  -e AGENT_WORKSPACE=/workspace \
  -e AGENT_HOME=/state/home \
  -e AGENT_ENTRYPOINT_BOOTSTRAP_ONLY=1 \
  -e AGENTIC_DEFAULT_MODEL=nemotron-cascade-2:30b \
  -e AGENTIC_CODEX_CATALOG_MODELS='qwen3.5:35b,custom-local:7b' \
  -v "${tmp_dir}/state":/state \
  -v "${tmp_dir}/logs":/logs \
  -v "${tmp_dir}/workspace":/workspace \
  -v "${entrypoint}":/entrypoint:ro \
  --entrypoint /bin/bash \
  agentic/agent-cli-base:local /entrypoint true >/tmp/agent-f30-entrypoint.out \
  || fail "agent image bootstrap-only run failed"

docker run --rm -v "${tmp_dir}":/fixture alpine:3.21 \
  cat /fixture/state/bootstrap/codex-model-catalog.json >"${tmp_dir}/catalog.json"
python3 - "${tmp_dir}/catalog.json" <<'PY' || fail "Codex catalog must include metadata for non-default local models"
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
models = {item.get("slug") for item in payload.get("models", []) if isinstance(item, dict)}
expected = {"nemotron-cascade-2:30b", "qwen3.5:35b", "custom-local:7b"}
missing = expected - models
if missing:
    raise SystemExit(f"missing catalog models: {sorted(missing)}")
PY

ok "Codex catalog supports seeded and gate-discovered local models"
