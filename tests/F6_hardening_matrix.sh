#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F6 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

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
import os
import sys

config_path = sys.argv[1]
with open(config_path, "r", encoding="utf-8") as fh:
    cfg = json.load(fh)

profile = os.environ.get("AGENTIC_PROFILE", "strict-prod")
services = cfg.get("services", {})
if not services:
    raise SystemExit("compose config rendered with no services")

root_user_allowed_exceptions = {
    "ollama",
    "unbound",
    "egress-proxy",
    "promtail",
    "cadvisor",
    "dcgm-exporter",
}
strict_root_required = {
    "unbound",
    "egress-proxy",
    "cadvisor",
    "dcgm-exporter",
}
if profile == "strict-prod":
    strict_root_required.add("ollama")
    strict_root_required.add("promtail")
readwrite_rootfs_exceptions = {"ollama", "egress-proxy", "opensearch", "optional-forgejo"}
agent_services = {"agentic-claude", "agentic-codex", "agentic-opencode", "agentic-kilocode", "agentic-vibestral", "agentic-hermes"}
agent_nnp = os.environ.get("AGENTIC_AGENT_NO_NEW_PRIVILEGES", "true").strip().lower()
if agent_nnp not in {"true", "false"}:
    agent_nnp = "true"


def is_non_root(user_value: object) -> bool:
    user = str(user_value or "").strip()
    return user not in {"", "0", "root", "0:0", "root:root"}


missing_healthcheck = sorted(
    service for service, service_cfg in services.items() if "healthcheck" not in service_cfg
)
if missing_healthcheck:
    raise SystemExit(f"services missing healthcheck: {', '.join(missing_healthcheck)}")

security_failures: list[str] = []
for service, service_cfg in sorted(services.items()):
    cap_drop = [str(value) for value in service_cfg.get("cap_drop", [])]
    if "ALL" not in cap_drop:
        security_failures.append(f"{service}: cap_drop missing ALL")

    security_opt = [str(value) for value in service_cfg.get("security_opt", [])]
    expected_nnp = "no-new-privileges:true"
    if service in agent_services and agent_nnp == "false":
        expected_nnp = "no-new-privileges:false"
    if expected_nnp not in security_opt:
        security_failures.append(f"{service}: security_opt missing {expected_nnp}")

    if service not in readwrite_rootfs_exceptions and service_cfg.get("read_only") is not True:
        security_failures.append(f"{service}: read_only must be true")

    user_value = service_cfg.get("user")
    if service in strict_root_required:
        normalized = str(user_value or "").strip()
        if normalized not in {"0", "root", "0:0", "root:root"}:
            security_failures.append(f"{service}: must keep explicit root user exception (actual={normalized or '<empty>'})")
    elif service in root_user_allowed_exceptions:
        normalized = str(user_value or "").strip()
        if normalized == "":
            security_failures.append(f"{service}: user must be explicit even when root exception is allowed")
    else:
        if not is_non_root(user_value):
            security_failures.append(f"{service}: user must be non-root (actual={user_value!r})")

if security_failures:
    raise SystemExit("hardening matrix violations:\n" + "\n".join(f"- {item}" for item in security_failures))
PY

ok "F6_hardening_matrix passed"
