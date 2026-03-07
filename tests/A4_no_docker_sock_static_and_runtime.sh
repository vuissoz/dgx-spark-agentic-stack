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

docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" \
  -f "${AGENTIC_COMPOSE_DIR}/compose.core.yml" \
  -f "${AGENTIC_COMPOSE_DIR}/compose.agents.yml" \
  -f "${AGENTIC_COMPOSE_DIR}/compose.ui.yml" \
  -f "${AGENTIC_COMPOSE_DIR}/compose.obs.yml" \
  -f "${AGENTIC_COMPOSE_DIR}/compose.rag.yml" \
  -f "${AGENTIC_COMPOSE_DIR}/compose.optional.yml" \
  config --no-env-resolution --format json >"${config_json_file}"

python3 - "${config_json_file}" <<'PY'
import json
import sys

config_path = sys.argv[1]
with open(config_path, "r", encoding="utf-8") as fh:
    cfg = json.load(fh)

matches = []


def walk(node, path):
    if isinstance(node, dict):
        for key, value in node.items():
            walk(value, path + [str(key)])
        return
    if isinstance(node, list):
        for idx, value in enumerate(node):
            walk(value, path + [f"[{idx}]"])
        return
    if isinstance(node, str) and "docker.sock" in node:
        matches.append((".".join(path), node))


walk(cfg, [])

if matches:
    lines = ["docker.sock reference(s) found in rendered compose config:"]
    for path, value in matches:
        lines.append(f"- {path}: {value}")
    raise SystemExit("\n".join(lines))
PY

ok "static compose config contains no docker.sock reference"

mapfile -t running_services < <(
  docker ps \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --format '{{.ID}}|{{.Label "com.docker.compose.service"}}' \
    | sort -t'|' -k2,2
)

[[ "${#running_services[@]}" -gt 0 ]] \
  || fail "no running containers found for compose project '${AGENTIC_COMPOSE_PROJECT}' (runtime check requires a deployed stack)"

for row in "${running_services[@]}"; do
  cid="${row%%|*}"
  service="${row#*|}"
  [[ -n "${cid}" && -n "${service}" ]] || continue

  assert_no_docker_sock_mount "${cid}" \
    || fail "service '${service}' mounts docker.sock at runtime"
done

ok "runtime mounts contain no docker.sock across compose project '${AGENTIC_COMPOSE_PROJECT}'"
ok "A4_no_docker_sock_static_and_runtime passed"
