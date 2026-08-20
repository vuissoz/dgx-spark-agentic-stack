#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K18 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd curl
assert_cmd docker
assert_cmd python3

config_json_file="$(mktemp)"
trap 'rm -f "${config_json_file}"' EXIT

COMPOSE_PROFILES=optional-n8n docker compose \
  --project-name "${AGENTIC_COMPOSE_PROJECT}" \
  -f "${AGENTIC_COMPOSE_DIR}/compose.optional.yml" \
  config --format json >"${config_json_file}"

python3 - "${config_json_file}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as config_file:
    service = json.load(config_file)["services"]["optional-n8n"]

targets = {volume["target"] for volume in service.get("volumes", [])}
if "/home/node/.n8n" not in targets:
    raise SystemExit("optional-n8n persistent data mount is missing")
if "/home/node/.n8n/config" in targets:
    raise SystemExit("optional-n8n must not mount a directory over its config file")
tmpfs_targets = {
    entry.split(":", 1)[0] if isinstance(entry, str) else entry["target"]
    for entry in service.get("tmpfs", [])
}
if "/home/node/.cache" not in tmpfs_targets:
    raise SystemExit("optional-n8n must provide a writable cache tmpfs with read-only rootfs")
PY
ok "n8n compose mount layout reserves /home/node/.n8n/config for a file"

"${agent_bin}" stop n8n >/tmp/agent-k18-stop-pre.out 2>&1 || true
"${REPO_ROOT}/deployments/optional/init_runtime.sh"

AGENTIC_OPTIONAL_MODULES=n8n "${agent_bin}" up optional >/tmp/agent-k18-up.out \
  || fail "agent up optional (n8n) failed"

n8n_cid="$(require_service_container optional-n8n)" || exit 1
n8n_loopback_cid="$(require_service_container optional-n8n-loopback)" || exit 1
wait_for_container_ready "${n8n_cid}" 120 || fail "optional-n8n did not become ready"
wait_for_container_ready "${n8n_loopback_cid}" 120 || fail "optional-n8n-loopback did not become ready"

mount_dump="$(docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "${n8n_cid}")"
grep -qx '/home/node/.n8n' <<<"${mount_dump}" \
  || fail "optional-n8n persistent data mount is missing at runtime"
if grep -qx '/home/node/.n8n/config' <<<"${mount_dump}"; then
  fail "optional-n8n has a conflicting runtime mount at /home/node/.n8n/config"
fi

timeout 20 docker exec "${n8n_cid}" sh -ec 'test -f /home/node/.n8n/config' \
  || fail "n8n did not create /home/node/.n8n/config as a file"
timeout 20 docker exec "${n8n_cid}" sh -ec 'test -w /home/node/.cache' \
  || fail "n8n cache tmpfs is not writable by the runtime user"

n8n_port="${N8N_HOST_PORT:-5678}"
assert_no_public_bind "${n8n_port}" || fail "optional-n8n must stay loopback-only"
curl -fsS "http://127.0.0.1:${n8n_port}/healthz" >/dev/null \
  || fail "optional-n8n loopback health endpoint is unreachable"

# n8n announces readiness before finishing static asset generation. Keep the
# probe alive long enough to catch a late read-only cache failure.
sleep 10
wait_for_container_ready "${n8n_cid}" 20 || fail "optional-n8n became unhealthy after initial readiness"
curl -fsS "http://127.0.0.1:${n8n_port}/healthz" >/dev/null \
  || fail "optional-n8n loopback endpoint became unreachable after startup"

assert_container_security "${n8n_cid}" || fail "optional-n8n security baseline failed"
assert_no_docker_sock_mount "${n8n_cid}" || fail "optional-n8n must not mount docker.sock"

ok "K18_n8n passed"
