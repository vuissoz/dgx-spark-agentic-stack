#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

assert_cmd docker
assert_cmd python3

config_json_file="$(mktemp)"
trap 'rm -f "${config_json_file}"' EXIT

N8N_SANDBOX_API_KEY=test-api \
N8N_SANDBOX_RUNNER_REGISTRATION_TOKEN=test-registration \
N8N_SANDBOX_RUNNER_API_KEY=test-runner \
N8N_SEARXNG_SECRET=test-searxng \
AGENTIC_N8N_AI_MODEL=qwen3.8 \
N8N_INSTANCE_AI_SANDBOX_ENABLED=true \
COMPOSE_PROFILES=optional-n8n-ai \
docker compose \
  --project-name "${AGENTIC_COMPOSE_PROJECT}" \
  -f "${AGENTIC_COMPOSE_DIR}/compose.optional.yml" \
  config --format json >"${config_json_file}"

python3 - "${config_json_file}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    config = json.load(handle)

services = config["services"]
required = {
    "optional-n8n",
    "optional-n8n-loopback",
    "optional-n8n-sandbox-tls",
    "optional-n8n-sandbox-registry",
    "optional-n8n-sandbox-image-seed",
    "optional-n8n-sandbox-api",
    "optional-n8n-sandbox-runner",
    "optional-n8n-searxng",
}
missing = sorted(required - services.keys())
if missing:
    raise SystemExit(f"missing n8n-ai services: {missing}")

runner = services["optional-n8n-sandbox-runner"]
if runner.get("runtime") != "sysbox-runc":
    raise SystemExit("sandbox runner must use sysbox-runc")
if runner.get("privileged", False):
    raise SystemExit("sandbox runner must not be privileged")

for name in required:
    service = services[name]
    if service.get("ports"):
        if name != "optional-n8n-loopback":
            raise SystemExit(f"{name} must not publish host ports")
    for mount in service.get("volumes", []):
        source = mount.get("source", "") if isinstance(mount, dict) else str(mount).split(":", 1)[0]
        if source in {"/var/run/docker.sock", "/run/docker.sock"}:
            raise SystemExit(f"{name} mounts host docker.sock")

network = config["networks"]["n8n-sandbox"]
if not network.get("internal"):
    raise SystemExit("n8n sandbox network must be internal")

n8n_env = services["optional-n8n"]["environment"]
expected = {
    "N8N_INSTANCE_AI_MODEL": "qwen3.8",
    "N8N_INSTANCE_AI_MODEL_URL": "http://ollama-gate:11435/v1",
    "N8N_INSTANCE_AI_SANDBOX_ENABLED": "true",
    "N8N_INSTANCE_AI_SANDBOX_PROVIDER": "n8n-sandbox",
    "N8N_INSTANCE_AI_SANDBOX_API_URL": "http://optional-n8n-sandbox-api:8080",
    "N8N_INSTANCE_AI_SEARXNG_URL": "http://optional-n8n-searxng:8080",
}
for key, value in expected.items():
    if str(n8n_env.get(key)) != value:
        raise SystemExit(f"{key} mismatch: {n8n_env.get(key)!r}")
PY

ok "K19_n8n_local_ai_sandbox passed"
