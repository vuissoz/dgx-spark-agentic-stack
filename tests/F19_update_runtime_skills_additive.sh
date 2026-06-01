#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
runtime_root="$(mktemp -d)"
export AGENTIC_PROFILE="rootless-dev"
export AGENTIC_ROOT="${runtime_root}/agentic"
export AGENTIC_COMPOSE_PROJECT="agentic-f19-$$"
export AGENTIC_NETWORK="agentic-f19-$$"
export AGENTIC_LLM_NETWORK="agentic-f19-$$-llm"
export AGENTIC_EGRESS_NETWORK="agentic-f19-$$-egress"
export AGENTIC_DOCKER_USER_SOURCE_NETWORKS="${AGENTIC_NETWORK},${AGENTIC_EGRESS_NETWORK}"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F19 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd python3

trap 'docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${REPO_ROOT}/compose/compose.core.yml" down >/tmp/agent-f19-down-post.out 2>&1 || true; rm -rf "${runtime_root}"' EXIT

docker network create \
  --driver bridge \
  --internal \
  --label "com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
  --label "com.docker.compose.network=agentic" \
  "${AGENTIC_NETWORK}" >/dev/null 2>&1 || true
docker network create \
  --driver bridge \
  --internal \
  --label "com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
  --label "com.docker.compose.network=agentic-llm" \
  "${AGENTIC_LLM_NETWORK}" >/dev/null 2>&1 || true
docker network create \
  --driver bridge \
  --label "com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
  --label "com.docker.compose.network=agentic-egress" \
  "${AGENTIC_EGRESS_NETWORK}" >/dev/null 2>&1 || true

"${agent_bin}" down core >/tmp/agent-f19-down-pre.out 2>&1 || true
"${REPO_ROOT}/deployments/core/init_runtime.sh"

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
plugin_skills_dir="${agentic_root}/openclaw/state/cli/openclaw-home/.openclaw/extensions/stack-default-skills/skills"
managed_skills_dir="${agentic_root}/openclaw/state/cli/openclaw-home/.openclaw/skills"
managed_skill_name="find-skills"
extra_skill_name="user-extra-skill"

rm -rf "${plugin_skills_dir:?}/${managed_skill_name}" "${managed_skills_dir:?}/${managed_skill_name}"
install -d -m 0770 "${managed_skills_dir}/${extra_skill_name}"
cat >"${managed_skills_dir}/${extra_skill_name}/SKILL.md" <<'EOF_SKILL'
# user-extra-skill

Locally added extra skill used to verify additive runtime sync during `agent update`.
EOF_SKILL

update_output="$("${agent_bin}" update)"
release_id="$(printf '%s\n' "${update_output}" | sed -n 's/^update completed, release=//p' | tail -n 1)"
[[ -n "${release_id}" ]] || fail "agent update did not return a release id"

[[ -f "${plugin_skills_dir}/${managed_skill_name}/SKILL.md" ]] \
  || fail "agent update must restore missing managed skill '${managed_skill_name}' in the default-skills plugin runtime"
[[ -f "${managed_skills_dir}/${managed_skill_name}/SKILL.md" ]] \
  || fail "agent update must restore missing managed skill '${managed_skill_name}' in the managed skills runtime"
[[ -f "${managed_skills_dir}/${extra_skill_name}/SKILL.md" ]] \
  || fail "agent update must preserve extra unmanaged skill '${extra_skill_name}'"

openclaw_cid="$(require_service_container openclaw)" || exit 1
wait_for_container_ready "${openclaw_cid}" 120 || fail "openclaw did not become ready for F19"

timeout 30 docker exec "${openclaw_cid}" sh -lc 'openclaw skills list --json >/tmp/agent-f19-openclaw-skills-list.json 2>/tmp/agent-f19-openclaw-skills-list.err' \
  || fail "openclaw skills list --json must succeed after agent update runtime sync"
docker exec "${openclaw_cid}" sh -lc "python3 - <<'PY'
import json
from pathlib import Path

payload = json.loads(Path('/tmp/agent-f19-openclaw-skills-list.json').read_text(encoding='utf-8'))
skills = payload.get('skills', []) if isinstance(payload, dict) else []
names = set()
for item in skills:
    if not isinstance(item, dict):
        continue
    value = item.get('name')
    if isinstance(value, str) and value:
        names.add(value)

expected = {'find-skills', 'user-extra-skill'}
missing = sorted(expected - names)
if missing:
    raise SystemExit('missing skills after update: ' + ', '.join(missing))
PY" || fail "openclaw skills list must contain both restored managed skills and preserved extra skills after agent update"

ok "F19_update_runtime_skills_additive passed"
