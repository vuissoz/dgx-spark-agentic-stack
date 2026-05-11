#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

if [[ "${AGENTIC_SKIP_K_TESTS:-0}" == "1" ]]; then
  ok "K10 skipped because AGENTIC_SKIP_K_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd curl
assert_cmd python3

"${agent_bin}" down optional >/tmp/agent-k10-down-optional-pre.out 2>&1 || true
"${agent_bin}" down ui >/tmp/agent-k10-down-ui-pre.out 2>&1 || true
"${agent_bin}" down agents >/tmp/agent-k10-down-agents-pre.out 2>&1 || true
"${agent_bin}" down core >/tmp/agent-k10-down-core-pre.out 2>&1 || true

"${REPO_ROOT}/deployments/core/init_runtime.sh"
"${REPO_ROOT}/deployments/agents/init_runtime.sh"
"${REPO_ROOT}/deployments/ui/init_runtime.sh"
"${REPO_ROOT}/deployments/optional/init_runtime.sh"

"${agent_bin}" up core >/tmp/agent-k10-up-core.out \
  || fail "agent up core failed"
"${agent_bin}" up agents >/tmp/agent-k10-up-agents.out \
  || fail "agent up agents failed"
"${agent_bin}" up ui >/tmp/agent-k10-up-ui.out \
  || fail "agent up ui failed"

openhands_cid="$(require_service_container openhands)" || exit 1
wait_for_container_ready "${openhands_cid}" 180 || fail "openhands did not become ready"

forgejo_cid="$(require_service_container optional-forgejo)" || exit 1
wait_for_container_ready "${forgejo_cid}" 180 || fail "optional-forgejo did not become ready"
assert_container_security "${forgejo_cid}" || fail "optional-forgejo security baseline failed"
assert_no_docker_sock_mount "${forgejo_cid}" || fail "optional-forgejo must not mount docker.sock"

git_forge_port="${GIT_FORGE_HOST_PORT:-13010}"
assert_no_public_bind "${git_forge_port}" || fail "optional-forgejo must stay loopback-only"

bootstrap_state="${AGENTIC_ROOT}/optional/git/bootstrap/git-forge-bootstrap.json"
[[ -s "${bootstrap_state}" ]] || fail "bootstrap state file missing: ${bootstrap_state}"

admin_user="${GIT_FORGE_ADMIN_USER:-system-manager}"
admin_password_file="${AGENTIC_ROOT}/secrets/runtime/git-forge/${admin_user}.password"
[[ -s "${admin_password_file}" ]] || fail "git-forge admin password file missing: ${admin_password_file}"
admin_password="$(tr -d '\n' <"${admin_password_file}")"
shared_namespace="${GIT_FORGE_SHARED_NAMESPACE:-agentic}"
shared_repository="${GIT_FORGE_SHARED_REPOSITORY:-shared-workbench}"
reference_repository="${GIT_FORGE_REFERENCE_REPOSITORY:-eight-queens-agent-e2e}"

python3 - "${git_forge_port}" "${admin_user}" "${admin_password}" "${shared_namespace}" "${shared_repository}" "${reference_repository}" <<'PY' \
  || fail "git-forge API bootstrap verification failed"
import base64
import json
import sys
import urllib.error
import urllib.request

port, username, password, org, shared_repo, reference_repo = sys.argv[1:7]
base = f"http://127.0.0.1:{port}"
token = base64.b64encode(f"{username}:{password}".encode()).decode()
headers = {
    "Authorization": f"Basic {token}",
    "Accept": "application/json",
}

users = [
    "openclaw",
    "openhands",
    "comfyui",
    "claude",
    "codex",
    "opencode",
    "vibestral",
    "hermes",
    "pi-mono",
    "goose",
]

def request(path: str):
    req = urllib.request.Request(f"{base}{path}", headers=headers)
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.loads(response.read().decode("utf-8"))

request(f"/api/v1/orgs/{org}")
request(f"/api/v1/repos/{org}/{shared_repo}")
request(f"/api/v1/repos/{org}/{reference_repo}")

for user in users:
    request(f"/api/v1/users/{user}")

protections = request(f"/api/v1/repos/{org}/{reference_repo}/branch_protections")
assert isinstance(protections, list) and protections
main_rules = [rule for rule in protections if isinstance(rule, dict) and rule.get("branch_name") == "main"]
assert main_rules, protections
rule = main_rules[0]
assert rule.get("enable_push") is True
assert username in (rule.get("push_whitelist_usernames") or [])
PY

python3 - "${bootstrap_state}" "${reference_repository}" <<'PY' \
  || fail "git-forge bootstrap state must include the reference repo contract"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload.get("reference_repository") == sys.argv[2]
branch_policy = payload.get("reference_branch_policy") or {}
branches = set(branch_policy.get("agent_branches") or [])
expected = {
    "agent/codex",
    "agent/openclaw",
    "agent/claude",
    "agent/opencode",
    "agent/kilocode",
    "agent/openhands",
    "agent/pi-mono",
    "agent/goose",
    "agent/vibestral",
    "agent/hermes",
}
assert branches == expected
assert branch_policy.get("protected_branch") == "main"
ssh_contract = payload.get("ssh_contract") or {}
paths = ssh_contract.get("managed_paths") or {}
assert ssh_contract.get("known_hosts_filename") == "known_hosts"
assert paths.get("codex") == "/state/home/.ssh"
assert paths.get("openhands") == "/.openhands/home/.ssh"
assert paths.get("comfyui") == "/comfyui/user/.ssh"
PY

for mapping in \
  "agentic-claude|claude|/state/home/.ssh" \
  "agentic-codex|codex|/state/home/.ssh" \
  "agentic-opencode|opencode|/state/home/.ssh" \
  "agentic-kilocode|kilocode|/state/home/.ssh" \
  "agentic-vibestral|vibestral|/state/home/.ssh" \
  "agentic-hermes|hermes|/state/home/.ssh" \
  "openclaw|openclaw|/state/cli/openclaw-home/.ssh" \
  "openhands|openhands|/.openhands/home/.ssh" \
  "comfyui|comfyui|/comfyui/user/.ssh" \
  "optional-pi-mono|pi-mono|/state/home/.ssh" \
  "optional-goose|goose|/state/home/.ssh"; do
  service="${mapping%%|*}"
  rest="${mapping#*|}"
  account="${rest%%|*}"
  ssh_dir="${rest#*|}"
  cid="$(require_service_container "${service}")" || exit 1
  if ! timeout 30 docker exec "${cid}" sh -lc 'command -v git >/dev/null'; then
    fail "${service} does not expose git after git-forge bootstrap"
  fi
  if ! timeout 30 docker exec "${cid}" sh -lc 'test -r /run/secrets/git-forge.password'; then
    fail "${service} cannot read /run/secrets/git-forge.password"
  fi
  if ! timeout 30 docker exec "${cid}" sh -lc "test -n \"\$(git config --global user.name)\" && test \"\$(git config --global user.email)\" = \"${account}@forge.agentic.local\""; then
    fail "${service} git user.name is not configured"
  fi
  if ! timeout 30 docker exec "${cid}" sh -lc "test -r '${ssh_dir}/id_ed25519' && test -r '${ssh_dir}/id_ed25519.pub' && test -r '${ssh_dir}/known_hosts'"; then
    fail "${service} canonical SSH material is missing under ${ssh_dir}"
  fi
  if ! timeout 30 docker exec "${cid}" sh -lc "ssh_cmd=\"\$(git config core.sshCommand)\"; printf '%s\n' \"\${ssh_cmd}\" | grep -F -- '-i ${ssh_dir}/id_ed25519' >/dev/null && printf '%s\n' \"\${ssh_cmd}\" | grep -F -- 'UserKnownHostsFile=${ssh_dir}/known_hosts' >/dev/null"; then
    fail "${service} git sshCommand does not use the canonical SSH path"
  fi
  if ! timeout 45 docker exec "${cid}" sh -lc "GIT_TERMINAL_PROMPT=0 git ls-remote http://optional-forgejo:3000/${shared_namespace}/${shared_repository}.git HEAD >/dev/null"; then
    fail "${service} cannot access the shared forge repository"
  fi
  if ! timeout 45 docker exec "${cid}" sh -lc "GIT_SSH_COMMAND='ssh -F /dev/null -i ${ssh_dir}/id_ed25519 -o UserKnownHostsFile=${ssh_dir}/known_hosts -o StrictHostKeyChecking=yes' GIT_TERMINAL_PROMPT=0 git ls-remote ssh://git@optional-forgejo:2222/${shared_namespace}/${shared_repository}.git HEAD >/dev/null"; then
    fail "${service} cannot access the shared forge repository through canonical SSH"
  fi
done

codex_cid="$(require_service_container agentic-codex)" || exit 1
goose_cid="$(require_service_container optional-goose)" || exit 1

timeout 90 docker exec "${codex_cid}" sh -lc "
  set -eu
  rm -rf /workspace/git-forge-smoke-codex
  git clone http://optional-forgejo:3000/${shared_namespace}/${reference_repository}.git /workspace/git-forge-smoke-codex
  cd /workspace/git-forge-smoke-codex
  git checkout -B agent/codex origin/agent/codex
  printf 'codex-smoke\n' > codex-smoke.txt
  git add codex-smoke.txt
  git commit -m 'codex smoke commit'
  git push origin HEAD:agent/codex
" >/tmp/agent-k10-codex-smoke.out 2>&1 \
  || fail "codex clone/commit/push smoke failed on agent/codex"

if timeout 90 docker exec "${codex_cid}" sh -lc "
  set -eu
  cd /workspace/git-forge-smoke-codex
  git push origin HEAD:main
" >/tmp/agent-k10-codex-main-push.out 2>&1; then
  fail "codex push to protected main must fail on the reference repository"
fi

timeout 90 docker exec "${goose_cid}" sh -lc "
  set -eu
  rm -rf /workspace/git-forge-smoke-goose
  git clone http://optional-forgejo:3000/${shared_namespace}/${reference_repository}.git /workspace/git-forge-smoke-goose
  cd /workspace/git-forge-smoke-goose
  git checkout -B agent/goose origin/agent/goose
  test -f README.md
  test -f AGENT.md
  test -f .gitignore
  test -f .agentic/reference-e2e.manifest.json
  grep -qx '__pycache__/' .gitignore
  grep -qx '\*.py\[cod\]' .gitignore
  grep -q 'git status --short' AGENT.md
  grep -q 'Never push to `main`' AGENT.md
" >/tmp/agent-k10-goose-smoke.out 2>&1 \
  || fail "goose clone/share smoke failed on the reference repository"

ok "K10_git_forge passed"
