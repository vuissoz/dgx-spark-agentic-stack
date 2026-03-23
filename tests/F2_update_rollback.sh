#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F2 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd docker
assert_cmd python3

update_output_a="$("${agent_bin}" update)"
release_a="$(printf '%s\n' "${update_output_a}" | sed -n 's/^update completed, release=//p' | tail -n 1)"
[[ -n "${release_a}" ]] || fail "agent update did not return a release id (first update)"
release_dir_a="${AGENTIC_ROOT:-/srv/agentic}/deployments/releases/${release_a}"
[[ -f "${release_dir_a}/images.json" ]] || fail "missing images.json in first release ${release_a}"
[[ -f "${release_dir_a}/compose.effective.yml" ]] || fail "missing compose.effective.yml in first release ${release_a}"
[[ -f "${release_dir_a}/health_report.json" ]] || fail "missing health_report.json in first release ${release_a}"
[[ -f "${release_dir_a}/latest-resolution.json" ]] || fail "missing latest-resolution.json in first release ${release_a}"
ok "first update created complete snapshot ${release_a}"

sleep 1
update_output_b="$("${agent_bin}" update)"
release_b="$(printf '%s\n' "${update_output_b}" | sed -n 's/^update completed, release=//p' | tail -n 1)"
[[ -n "${release_b}" ]] || fail "agent update did not return a release id (second update)"
release_dir_b="${AGENTIC_ROOT:-/srv/agentic}/deployments/releases/${release_b}"
[[ -f "${release_dir_b}/images.json" ]] || fail "missing images.json in second release ${release_b}"
[[ -f "${release_dir_b}/latest-resolution.json" ]] || fail "missing latest-resolution.json in second release ${release_b}"
ok "second update created snapshot ${release_b}"

if cmp -s "${release_dir_a}/images.json" "${release_dir_b}/images.json"; then
  warn "no image digest drift observed between ${release_a} and ${release_b}; rollback validation continues on deterministic re-pin"
else
  ok "image manifest changed between ${release_a} and ${release_b}"
fi

"${agent_bin}" rollback all "${release_a}" >/tmp/agent-f2-rollback.out

python3 - "${release_dir_a}/images.json" "${AGENTIC_COMPOSE_PROJECT:-agentic}" <<'PY'
import json
import subprocess
import sys

images_path = sys.argv[1]
project = sys.argv[2]

with open(images_path, "r", encoding="utf-8") as fh:
    snapshot = json.load(fh)

expected = {}
for item in snapshot:
    service = item.get("service")
    if not service:
        continue
    pinned = item.get("repo_digest") or item.get("resolved_image") or item.get("configured_image")
    if pinned:
        expected[service] = pinned

for service, pinned in sorted(expected.items()):
    ps = subprocess.run(
        [
            "docker",
            "ps",
            "--filter",
            f"label=com.docker.compose.project={project}",
            "--filter",
            f"label=com.docker.compose.service={service}",
            "--format",
            "{{.ID}}",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    cid = ps.stdout.strip().splitlines()
    if not cid:
        raise SystemExit(f"service '{service}' is missing after rollback")
    cid = cid[0]

    inspect = subprocess.run(
        ["docker", "inspect", "--format", "{{.Image}}|{{.Config.Image}}", cid],
        check=True,
        capture_output=True,
        text=True,
    )
    resolved, configured = inspect.stdout.strip().split("|", 1)

    if pinned.startswith("sha256:"):
        if resolved != pinned:
            raise SystemExit(
                f"service '{service}' image mismatch after rollback: expected resolved {pinned}, got {resolved}"
            )
    else:
        if configured != pinned:
            raise SystemExit(
                f"service '{service}' image mismatch after rollback: expected configured {pinned}, got {configured}"
            )
PY
ok "rollback restored expected pinned images from ${release_a}"

for service in ollama ollama-gate egress-proxy unbound toolbox; do
  cid="$(service_container_id "${service}")"
  [[ -n "${cid}" ]] || continue
  wait_for_container_ready "${cid}" 120 || fail "service ${service} is not ready after rollback"
done
ok "critical services are healthy after rollback"

ok "F2_update_rollback passed"
