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
echo "${env_dump}" | grep -q '^OPENAI_BASE_URL=http://ollama-gate:11435/v1$' \
  || fail "optional-pi-mono must set OPENAI_BASE_URL=http://ollama-gate:11435/v1"
echo "${env_dump}" | grep -q '^OPENAI_API_KEY=ollama$' \
  || fail "optional-pi-mono must set OPENAI_API_KEY=ollama for local provider contract"

default_model="$(printf '%s\n' "${env_dump}" | sed -n 's/^AGENTIC_DEFAULT_MODEL=//p' | head -n 1)"
[[ -n "${default_model}" ]] || fail "optional-pi-mono must expose AGENTIC_DEFAULT_MODEL"

mount_dump="$(docker inspect --format '{{range .Mounts}}{{printf "%s|%s|%v\n" .Source .Destination .RW}}{{end}}' "${pi_mono_cid}")"
echo "${mount_dump}" | grep -q '|/run/secrets/gate_mcp.token|false$' \
  || fail "optional-pi-mono must mount gate_mcp.token read-only"

timeout 20 docker exec "${pi_mono_cid}" sh -lc 'test -d /state/home && test -w /state/home' \
  || fail "optional-pi-mono home must be writable at /state/home"
timeout 20 docker exec "${pi_mono_cid}" tmux has-session -t pi-mono \
  || fail "optional-pi-mono tmux session must exist"
timeout 20 docker exec "${pi_mono_cid}" node -e '
  const [major, minor] = process.versions.node.split(".").map(Number);
  if (major < 20 || (major === 20 && minor < 6)) process.exit(1);
' || fail "optional-pi-mono must provide Node.js >=20.6.0 (required by pi CLI)"

pi_real_path="$(timeout 20 docker exec "${pi_mono_cid}" sh -lc 'cat /etc/agentic/pi-real-path 2>/dev/null || true')"
if [[ -z "${pi_real_path}" || "${pi_real_path}" == "none" ]]; then
  warn "optional-pi-mono pi CLI binary unavailable (best-effort install); skipping runtime probe"
else
  timeout 20 docker exec "${pi_mono_cid}" sh -lc '
    set -e
    test -x "$(cat /etc/agentic/pi-real-path)"
    pi --version >/tmp/pi-cli.out 2>&1 || pi --help >/tmp/pi-cli.out 2>&1
    ! grep -Eq "Invalid regular expression flags|wrapper fallback" /tmp/pi-cli.out
  ' || fail "pi CLI runtime probe failed in optional-pi-mono"
fi

timeout 20 docker exec "${pi_mono_cid}" sh -lc "
  PI_EXPECTED_MODEL='${default_model}' python3 - <<'PY'
import json
import os
from pathlib import Path

models_path = Path('/state/home/.pi/agent/models.json')
settings_path = Path('/state/home/.pi/agent/settings.json')
if not models_path.exists() or not settings_path.exists():
    raise SystemExit(1)

models_payload = json.loads(models_path.read_text(encoding='utf-8'))
settings_payload = json.loads(settings_path.read_text(encoding='utf-8'))

providers = models_payload.get('providers')
if not isinstance(providers, dict):
    raise SystemExit(1)

provider = providers.get('ollama')
if not isinstance(provider, dict):
    raise SystemExit(1)
if provider.get('baseUrl') != 'http://ollama-gate:11435/v1':
    raise SystemExit(1)
if provider.get('api') != 'openai-completions':
    raise SystemExit(1)
if provider.get('apiKey') != 'ollama':
    raise SystemExit(1)

models = provider.get('models')
if not isinstance(models, list):
    raise SystemExit(1)
ids = {
    item.get('id').strip()
    for item in models
    if isinstance(item, dict) and isinstance(item.get('id'), str) and item.get('id').strip()
}
if os.environ['PI_EXPECTED_MODEL'] not in ids:
    raise SystemExit(1)
if settings_payload.get('defaultProvider') != 'ollama':
    raise SystemExit(1)
if settings_payload.get('defaultModel') != os.environ['PI_EXPECTED_MODEL']:
    raise SystemExit(1)
PY
" || fail "optional-pi-mono must reconcile ~/.pi/agent local provider defaults"

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
