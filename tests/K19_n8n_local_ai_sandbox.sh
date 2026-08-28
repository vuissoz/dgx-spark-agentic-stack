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

host_config="$(mktemp)"
guest_config="$(mktemp)"
guest_env="$(mktemp)"
trap 'rm -f "${host_config}" "${guest_config}" "${guest_env}"' EXIT

cat >"${guest_env}" <<'EOF'
SANDBOX_VM_BIND_IP=10.40.163.2
SANDBOX_API_KEYS=test-api
SANDBOX_API_RUNNER_REGISTRATION_TOKEN=test-registration
SANDBOX_API_RUNNER_API_KEY=test-runner
SANDBOX_RUNNER_API_KEYS=test-runner
SANDBOX_RUNNER_REGISTRATION_TOKEN=test-registration
SANDBOX_EGRESS_PROXY_URL=http://192.0.2.1:3128
EOF

N8N_SANDBOX_API_KEY=test-api \
N8N_SANDBOX_RUNNER_REGISTRATION_TOKEN=test-registration \
N8N_SANDBOX_RUNNER_API_KEY=test-runner \
N8N_SEARXNG_SECRET=test-searxng \
N8N_SANDBOX_SERVICE_URL=http://10.40.163.2:8080 \
N8N_SANDBOX_VM_IP=10.40.163.2 \
AGENTIC_N8N_AI_MODEL=qwen3.8 \
N8N_INSTANCE_AI_SANDBOX_ENABLED=true \
COMPOSE_PROFILES=optional-n8n-ai \
docker compose \
  --project-name "${AGENTIC_COMPOSE_PROJECT}" \
  -f "${AGENTIC_COMPOSE_DIR}/compose.optional.yml" \
  config --format json >"${host_config}"

SANDBOX_VM_BIND_IP=10.40.163.2 \
SANDBOX_EGRESS_PROXY_URL=http://192.0.2.1:3128 \
SANDBOX_VM_ENV_FILE="${guest_env}" \
docker compose \
  --project-name n8n-sandbox \
  --env-file "${guest_env}" \
  -f "${REPO_ROOT}/deployments/vm/n8n-sandbox/compose.yml" \
  config --format json >"${guest_config}"

python3 - "${host_config}" "${guest_config}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    host = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    guest = json.load(handle)

host_services = host["services"]
required_host = {"optional-n8n", "optional-n8n-loopback", "optional-n8n-searxng"}
missing = sorted(required_host - host_services.keys())
if missing:
    raise SystemExit(f"missing host n8n-ai services: {missing}")
for forbidden in (
    "optional-n8n-sandbox-api",
    "optional-n8n-sandbox-runner",
    "optional-n8n-sandbox-registry",
):
    if forbidden in host_services:
        raise SystemExit(f"sandbox service must not run in host Docker: {forbidden}")

n8n_env = host_services["optional-n8n"]["environment"]
expected = {
    "N8N_INSTANCE_AI_MODEL": "qwen3.8",
    "N8N_INSTANCE_AI_MODEL_URL": "http://ollama-gate:11435/v1",
    "N8N_INSTANCE_AI_SANDBOX_ENABLED": "true",
    "N8N_INSTANCE_AI_SANDBOX_PROVIDER": "n8n-sandbox",
    "N8N_INSTANCE_AI_SANDBOX_API_URL": "http://10.40.163.2:8080",
    "N8N_INSTANCE_AI_SEARXNG_URL": "http://optional-n8n-searxng:8080",
}
for key, value in expected.items():
    if str(n8n_env.get(key)) != value:
        raise SystemExit(f"{key} mismatch: {n8n_env.get(key)!r}")
if "agentic-egress" not in host_services["optional-n8n"].get("networks", {}):
    raise SystemExit("n8n must join controlled egress to reach the private Multipass VM")

guest_services = guest["services"]
required_guest = {"tls-init", "registry", "image-seed", "image-customize", "api", "runner"}
missing = sorted(required_guest - guest_services.keys())
if missing:
    raise SystemExit(f"missing sandbox VM services: {missing}")

runner = guest_services["runner"]
if runner.get("runtime") != "sysbox-runc" or runner.get("privileged", False):
    raise SystemExit("VM runner must use unprivileged sysbox-runc")
if str(runner.get("restart")) != "no":
    raise SystemExit("VM runner must not race the egress policy on guest boot")
for name, service in guest_services.items():
    for mount in service.get("volumes", []):
        source = mount.get("source", "") if isinstance(mount, dict) else str(mount).split(":", 1)[0]
        if source in {"/var/run/docker.sock", "/run/docker.sock"}:
            raise SystemExit(f"{name} mounts docker.sock")

api_ports = guest_services["api"].get("ports", [])
if len(api_ports) != 1 or api_ports[0].get("host_ip") != "10.40.163.2":
    raise SystemExit(f"VM API must bind only its private address: {api_ports!r}")
if not guest["networks"]["control"].get("internal"):
    raise SystemExit("sandbox control network must be internal")
if "seed-egress" in runner.get("networks", {}):
    raise SystemExit("sandbox runner must not have direct egress")
if "ingress" in runner.get("networks", {}):
    raise SystemExit("sandbox runner must not join the API ingress network")
if "sandbox-egress" not in runner.get("networks", {}):
    raise SystemExit("sandbox runner must join the fail-closed proxy egress network")
if runner["environment"].get("SANDBOX_RUNNER_DOCKER_SANDBOX_IMAGE") != "registry:5000/n8n-sandbox:proxied":
    raise SystemExit("runner must execute the proxy-injected local sandbox image")
seed_env = guest_services["image-seed"].get("environment", {})
if seed_env.get("HTTPS_PROXY") != "http://192.0.2.1:3128":
    raise SystemExit("sandbox image seed must use the monitored VM proxy tunnel")
PY

grep -Fq '127.0.0.1:${AGENTIC_PROXY_HOST_PORT:-3128}:3128' \
  "${REPO_ROOT}/compose/compose.core.yml" \
  || fail "host egress proxy must be published on loopback only"
grep -Fq 'iptables -A AGENTIC-SBX-EGRESS -j DROP' \
  "${REPO_ROOT}/deployments/vm/n8n-sandbox/provision_guest.sh" \
  || fail "inner sandbox direct egress must fail closed"
grep -Fq '/etc/apt/apt.conf.d/99agentic-proxy' \
  "${REPO_ROOT}/deployments/vm/n8n-sandbox/compose.yml" \
  || fail "sandbox image must include package-manager proxy configuration"

ok "K19_n8n_local_ai_sandbox passed"
