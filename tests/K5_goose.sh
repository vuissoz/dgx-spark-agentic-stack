#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K5 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker

"${agent_bin}" down optional >/tmp/agent-k5-down-pre.out 2>&1 || true
"${REPO_ROOT}/deployments/optional/init_runtime.sh"

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
install -d -m 0750 "${agentic_root}/deployments/optional"

cat >"${agentic_root}/deployments/optional/goose.request" <<'REQ'
need=Provide an isolated Goose runtime for controlled optional workflows.
success=Service is healthy and Goose session storage works with read-only rootfs.
owner=ops
expires_at=2099-12-31
REQ
chmod 0640 "${agentic_root}/deployments/optional/goose.request"

"${agent_bin}" doctor >/tmp/agent-k5-doctor.out \
  || fail "precondition failed: doctor must be green before validating K5"

AGENTIC_OPTIONAL_MODULES=goose "${agent_bin}" up optional >/tmp/agent-k5-up.out \
  || fail "agent up optional (goose) failed"

goose_cid="$(require_service_container optional-goose)" || exit 1
wait_for_container_ready "${goose_cid}" 120 || fail "optional-goose did not become ready"
assert_container_security "${goose_cid}" || fail "optional-goose container security baseline failed"
assert_proxy_enforced "${goose_cid}" || fail "optional-goose proxy env baseline failed"
assert_no_docker_sock_mount "${goose_cid}" || fail "optional-goose must not mount docker.sock"

env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${goose_cid}")"
echo "${env_dump}" | grep -q '^HOME=/state/home$' \
  || fail "optional-goose must set HOME=/state/home"
echo "${env_dump}" | grep -q '^XDG_CONFIG_HOME=/state/home/.config$' \
  || fail "optional-goose must set XDG_CONFIG_HOME=/state/home/.config"
echo "${env_dump}" | grep -q '^XDG_DATA_HOME=/state/home/.local/share$' \
  || fail "optional-goose must set XDG_DATA_HOME=/state/home/.local/share"
echo "${env_dump}" | grep -q '^XDG_STATE_HOME=/state/home/.local/state$' \
  || fail "optional-goose must set XDG_STATE_HOME=/state/home/.local/state"
echo "${env_dump}" | grep -q '^OLLAMA_HOST=http://ollama-gate:11435$' \
  || fail "optional-goose must set OLLAMA_HOST=http://ollama-gate:11435"

mount_dump="$(docker inspect --format '{{range .Mounts}}{{printf "%s|%s|%v\n" .Source .Destination .RW}}{{end}}' "${goose_cid}")"
echo "${mount_dump}" | grep -q '|/state|true$' \
  || fail "optional-goose must mount /state as writable"
echo "${mount_dump}" | grep -q '|/logs|true$' \
  || fail "optional-goose must mount /logs as writable"
echo "${mount_dump}" | grep -q '|/workspace|true$' \
  || fail "optional-goose must mount /workspace as writable"

timeout 30 docker exec "${goose_cid}" sh -lc 'goose session list >/tmp/goose-k5-session-list.out 2>&1' \
  || fail "optional-goose goose session list failed"
timeout 30 docker exec "${goose_cid}" sh -lc 'test -d /state/home && test -w /state/home' \
  || fail "optional-goose home must be writable at /state/home"
timeout 30 docker exec "${goose_cid}" sh -lc 'test -d /state/home/.local/share/goose/sessions && test -w /state/home/.local/share/goose/sessions' \
  || fail "optional-goose sessions dir must be writable"
timeout 30 docker exec "${goose_cid}" sh -lc 'test -d /state/home/.local/state/goose/logs && test -w /state/home/.local/state/goose/logs' \
  || fail "optional-goose logs dir must be writable"
timeout 30 docker exec "${goose_cid}" sh -lc 'test -f /state/home/.local/share/goose/sessions/sessions.db' \
  || fail "optional-goose sessions database must persist in /state/home/.local/share/goose/sessions/sessions.db"

goose_pwd="$(timeout 20 docker exec "${goose_cid}" sh -lc 'pwd')"
[[ "${goose_pwd}" == "/workspace" ]] \
  || fail "optional-goose working directory mismatch (expected=/workspace, actual=${goose_pwd})"

goose_project="k5-goose-${USER:-agent}-$$"
AGENT_NO_ATTACH=1 "${agent_bin}" goose "${goose_project}" >/tmp/agent-k5-goose.out \
  || fail "agent goose attach contract failed"
grep -q 'persistent tmux session' /tmp/agent-k5-goose.out \
  || fail "agent goose output is missing tmux persistence notice"
timeout 20 docker exec "${goose_cid}" tmux has-session -t goose \
  || fail "agent goose did not create/keep tmux session"
timeout 20 docker exec "${goose_cid}" sh -lc "test -d '/workspace/${goose_project}'" \
  || fail "agent goose did not create project workspace /workspace/${goose_project}"
goose_path="$(timeout 20 docker exec "${goose_cid}" tmux display-message -p -t goose '#{pane_current_path}')"
[[ "${goose_path}" == "/workspace/${goose_project}" ]] \
  || fail "agent goose tmux pane path mismatch (expected=/workspace/${goose_project}, actual=${goose_path})"

assert_no_public_bind || fail "goose activation must not introduce non-loopback listeners"

ok "K5_goose passed"
