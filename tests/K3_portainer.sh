#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K3 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd curl

"${agent_bin}" down optional >/tmp/agent-k3-down-pre.out 2>&1 || true

"${REPO_ROOT}/deployments/optional/init_runtime.sh"

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
install -d -m 0750 "${agentic_root}/deployments/optional"

cat >"${agentic_root}/deployments/optional/portainer.request" <<'REQ'
need=Provide temporary local-only UI visibility for manual stack inspection.
success=Portainer is reachable on loopback only and runs without docker.sock mount.
owner=ops
expires_at=2099-12-31
REQ
chmod 0640 "${agentic_root}/deployments/optional/portainer.request"

"${agent_bin}" doctor >/tmp/agent-k3-doctor.out \
  || fail "precondition failed: doctor must be green before validating K3"

AGENTIC_OPTIONAL_MODULES=portainer "${agent_bin}" up optional >/tmp/agent-k3-up.out \
  || fail "agent up optional (portainer) failed"

portainer_cid="$(require_service_container optional-portainer)" || exit 1
wait_for_container_ready "${portainer_cid}" 120 || fail "optional-portainer did not become ready"
assert_container_security "${portainer_cid}" || fail "optional-portainer container security baseline failed"
assert_no_docker_sock_mount "${portainer_cid}" || fail "optional-portainer must not mount docker.sock"

portainer_port="${PORTAINER_HOST_PORT:-9001}"
assert_no_public_bind "${portainer_port}" || fail "optional-portainer must stay loopback-only"

portainer_ready=0
for _ in $(seq 1 40); do
  status="$(curl -sS -o /tmp/agent-k3-portainer-http.out -w '%{http_code}' "http://127.0.0.1:${portainer_port}/" || true)"
  if [[ "${status}" =~ ^(200|301|302|401|403)$ ]]; then
    portainer_ready=1
    break
  fi
  sleep 1
done
[[ "${portainer_ready}" -eq 1 ]] || fail "optional-portainer endpoint is unreachable on loopback"

changes_log="${agentic_root}/deployments/changes.log"
[[ -s "${changes_log}" ]] || fail "changes log missing: ${changes_log}"
grep -q 'module=portainer' "${changes_log}" || fail "changes log must include a portainer activation record"

ok "K3_portainer passed"
