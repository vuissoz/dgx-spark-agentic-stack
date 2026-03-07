#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K4 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker

"${agent_bin}" down optional >/tmp/agent-k4-down-pre.out 2>&1 || true
"${REPO_ROOT}/deployments/optional/init_runtime.sh"

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
install -d -m 0750 "${agentic_root}/deployments/optional"

cat >"${agentic_root}/deployments/optional/pi-mono.request" <<'REQ'
need=Provide an additional isolated tmux-based coding agent runtime.
success=Service stays healthy and can be attached with agent pi-mono.
owner=ops
expires_at=2099-12-31
REQ
chmod 0640 "${agentic_root}/deployments/optional/pi-mono.request"

"${agent_bin}" doctor >/tmp/agent-k4-doctor.out \
  || fail "precondition failed: doctor must be green before validating K4"

AGENTIC_OPTIONAL_MODULES=pi-mono "${agent_bin}" up optional >/tmp/agent-k4-up.out \
  || fail "agent up optional (pi-mono) failed"

pi_mono_cid="$(require_service_container optional-pi-mono)" || exit 1
wait_for_container_ready "${pi_mono_cid}" 90 || fail "optional-pi-mono did not become ready"
assert_container_security "${pi_mono_cid}" || fail "optional-pi-mono container security baseline failed"
assert_proxy_enforced "${pi_mono_cid}" || fail "optional-pi-mono proxy env baseline failed"
assert_no_docker_sock_mount "${pi_mono_cid}" || fail "optional-pi-mono must not mount docker.sock"

env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${pi_mono_cid}")"
echo "${env_dump}" | grep -q '^HOME=/state/home$' \
  || fail "optional-pi-mono must set HOME=/state/home"
echo "${env_dump}" | grep -q '^AGENT_HOME=/state/home$' \
  || fail "optional-pi-mono must set AGENT_HOME=/state/home"
echo "${env_dump}" | grep -q '^GATE_MCP_URL=http://gate-mcp:8123$' \
  || fail "optional-pi-mono must set GATE_MCP_URL"
echo "${env_dump}" | grep -q '^GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token$' \
  || fail "optional-pi-mono must set GATE_MCP_AUTH_TOKEN_FILE"

mount_dump="$(docker inspect --format '{{range .Mounts}}{{printf "%s|%s|%v\n" .Source .Destination .RW}}{{end}}' "${pi_mono_cid}")"
echo "${mount_dump}" | grep -q '|/run/secrets/gate_mcp.token|false$' \
  || fail "optional-pi-mono must mount gate_mcp.token read-only"

timeout 20 docker exec "${pi_mono_cid}" sh -lc 'test -d /state/home && test -w /state/home' \
  || fail "optional-pi-mono home must be writable at /state/home"
timeout 20 docker exec "${pi_mono_cid}" tmux has-session -t pi-mono \
  || fail "optional-pi-mono tmux session must exist"

project_name="k4-pi-mono-${USER:-agent}-$$"
AGENT_NO_ATTACH=1 AGENT_PROJECT_NAME="${project_name}" "${agent_bin}" pi-mono >/tmp/agent-k4-pi-mono.out
grep -q 'persistent tmux session' /tmp/agent-k4-pi-mono.out \
  || fail "agent pi-mono output is missing tmux persistence notice"

timeout 20 docker exec "${pi_mono_cid}" sh -lc "test -d '/workspace/${project_name}'" \
  || fail "agent pi-mono did not create project workspace /workspace/${project_name}"
pi_mono_path="$(timeout 20 docker exec "${pi_mono_cid}" tmux display-message -p -t pi-mono '#{pane_current_path}')"
[[ "${pi_mono_path}" == "/workspace/${project_name}" ]] \
  || fail "agent pi-mono tmux pane path mismatch (expected=/workspace/${project_name}, actual=${pi_mono_path})"

assert_no_public_bind || fail "pi-mono activation must not introduce non-loopback listeners"

ok "K4_pi_mono passed"
