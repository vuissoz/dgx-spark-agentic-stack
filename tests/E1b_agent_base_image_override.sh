#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AGENTS_COMPOSE_FILE="${REPO_ROOT}/compose/compose.agents.yml"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_E_TESTS:-0}" == "1" ]]; then
  ok "E1b skipped because AGENTIC_SKIP_E_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd timeout

runtime_root="$(mktemp -d)"
custom_context="$(mktemp -d)"
default_cfg="$(mktemp)"
custom_cfg="$(mktemp)"
network_name="agentic-e1b-${RANDOM}"
project_name="agentic-e1b-${RANDOM}"
custom_image="${AGENTIC_AGENT_BASE_IMAGE_TEST_REF:-agentic/agent-cli-base:e1b-test}"
default_image="agentic/agent-cli-base:local"

cleanup() {
  AGENTIC_ROOT="${runtime_root}" \
  AGENTIC_NETWORK="${network_name}" \
  AGENTIC_COMPOSE_PROJECT="${project_name}" \
  AGENTIC_AGENT_BASE_BUILD_CONTEXT="${custom_context}" \
  AGENTIC_AGENT_BASE_DOCKERFILE="${custom_context}/Dockerfile" \
  AGENTIC_AGENT_BASE_IMAGE="${custom_image}" \
    docker compose --project-name "${project_name}" -f "${AGENTS_COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
  docker network rm "${network_name}" >/dev/null 2>&1 || true
  docker image rm "${custom_image}" >/dev/null 2>&1 || true
  rm -rf "${runtime_root}" "${custom_context}"
  rm -f "${default_cfg}" "${custom_cfg}"
}
trap cleanup EXIT

cat >"${custom_context}/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

tool="${AGENT_TOOL:-agent}"
session="${AGENT_SESSION:-${tool}}"
workspace="${AGENT_WORKSPACE:-/workspace}"
state_dir="${AGENT_STATE_DIR:-/state}"
logs_dir="${AGENT_LOGS_DIR:-/logs}"

mkdir -p "${workspace}" "${state_dir}" "${logs_dir}"

start_session() {
  tmux new-session -d -s "${session}" -c "${workspace}" "bash -lc 'exec bash -l'"
}

if ! tmux has-session -t "${session}" 2>/dev/null; then
  start_session
fi

while true; do
  sleep 5
  if ! tmux has-session -t "${session}" 2>/dev/null; then
    start_session
  fi
done
EOF
chmod 0755 "${custom_context}/entrypoint.sh"

cat >"${custom_context}/Dockerfile" <<'EOF'
FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    tmux \
  && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10031 agentcustom \
  && useradd --uid 10031 --gid 10031 --create-home --shell /bin/bash agentcustom

COPY entrypoint.sh /usr/local/bin/agent-entrypoint
RUN chmod 0755 /usr/local/bin/agent-entrypoint

ENV HOME=/home/agentcustom
WORKDIR /workspace
USER agentcustom:agentcustom
ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
EOF

docker compose --project-name "${project_name}" -f "${AGENTS_COMPOSE_FILE}" config >"${default_cfg}"
grep -q "image: ${default_image}" "${default_cfg}" \
  || fail "default config must reference '${default_image}'"
grep -q 'dockerfile: deployments/images/agent-cli-base/Dockerfile' "${default_cfg}" \
  || fail "default config must reference the fallback agent base Dockerfile"
ok "default compose config uses fallback agent base image and Dockerfile"

docker compose --project-name "${project_name}" -f "${AGENTS_COMPOSE_FILE}" build agentic-claude >/dev/null
docker image inspect "${default_image}" >/dev/null 2>&1 \
  || fail "default build did not produce ${default_image}"
ok "default build path produced ${default_image}"

AGENTIC_ROOT="${runtime_root}" \
AGENTIC_NETWORK="${network_name}" \
AGENTIC_COMPOSE_PROJECT="${project_name}" \
AGENTIC_AGENT_BASE_BUILD_CONTEXT="${custom_context}" \
AGENTIC_AGENT_BASE_DOCKERFILE="${custom_context}/Dockerfile" \
AGENTIC_AGENT_BASE_IMAGE="${custom_image}" \
  docker compose --project-name "${project_name}" -f "${AGENTS_COMPOSE_FILE}" config >"${custom_cfg}"

grep -q "image: ${custom_image}" "${custom_cfg}" \
  || fail "override config must reference custom image '${custom_image}'"
grep -q "context: ${custom_context}" "${custom_cfg}" \
  || fail "override config must reference custom build context '${custom_context}'"
grep -q "dockerfile: ${custom_context}/Dockerfile" "${custom_cfg}" \
  || fail "override config must reference custom Dockerfile '${custom_context}/Dockerfile'"
ok "override compose config resolves custom image/context/dockerfile"

AGENTIC_ROOT="${runtime_root}" AGENT_RUNTIME_UID="$(id -u)" AGENT_RUNTIME_GID="$(id -g)" \
  "${REPO_ROOT}/deployments/agents/init_runtime.sh" >/dev/null

docker network create "${network_name}" >/dev/null

mapfile -t agent_services < <(
  AGENTIC_ROOT="${runtime_root}" \
  AGENTIC_NETWORK="${network_name}" \
  AGENTIC_COMPOSE_PROJECT="${project_name}" \
  AGENTIC_AGENT_BASE_BUILD_CONTEXT="${custom_context}" \
  AGENTIC_AGENT_BASE_DOCKERFILE="${custom_context}/Dockerfile" \
  AGENTIC_AGENT_BASE_IMAGE="${custom_image}" \
    docker compose --project-name "${project_name}" -f "${AGENTS_COMPOSE_FILE}" config --services \
    | grep '^agentic-'
)
[[ "${#agent_services[@]}" -gt 0 ]] || fail "no agent services discovered in compose.agents.yml"

AGENTIC_ROOT="${runtime_root}" \
AGENTIC_NETWORK="${network_name}" \
AGENTIC_COMPOSE_PROJECT="${project_name}" \
AGENTIC_AGENT_BASE_BUILD_CONTEXT="${custom_context}" \
AGENTIC_AGENT_BASE_DOCKERFILE="${custom_context}/Dockerfile" \
AGENTIC_AGENT_BASE_IMAGE="${custom_image}" \
  docker compose --project-name "${project_name}" -f "${AGENTS_COMPOSE_FILE}" up -d "${agent_services[@]}"

docker image inspect "${custom_image}" >/dev/null 2>&1 \
  || fail "override build did not produce ${custom_image}"
ok "override build produced custom image tag ${custom_image}"

container_id_for_service() {
  local service="$1"
  docker ps \
    --filter "label=com.docker.compose.project=${project_name}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}' | head -n 1
}

for service in "${agent_services[@]}"; do
  cid="$(container_id_for_service "${service}")"
  [[ -n "${cid}" ]] || fail "service '${service}' is not running after override deployment"

  configured_image="$(docker inspect --format '{{.Config.Image}}' "${cid}")"
  [[ "${configured_image}" == "${custom_image}" ]] \
    || fail "service '${service}' must run with '${custom_image}' (actual='${configured_image}')"

  assert_container_security "${cid}"
  assert_no_docker_sock_mount "${cid}"
done
ok "all agent services use custom image and keep security invariants"

custom_user="$(docker image inspect --format '{{.Config.User}}' "${custom_image}")"
[[ -n "${custom_user}" && "${custom_user}" != "root" && "${custom_user}" != "0" ]] \
  || fail "custom image user must be non-root (actual='${custom_user}')"
timeout 30 docker run --rm --entrypoint sh "${custom_image}" -lc 'command -v bash tmux git curl >/dev/null' \
  || fail "custom image must include bash/tmux/git/curl"
ok "custom image contract satisfied (non-root user, required tools present)"

ok "E1b_agent_base_image_override passed"
