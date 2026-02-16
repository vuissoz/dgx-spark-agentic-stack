#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_J_TESTS:-0}" == "1" ]]; then
  ok "J1 skipped because AGENTIC_SKIP_J_TESTS=1"
  exit 0
fi

assert_cmd docker

qdrant_cid="$(require_service_container qdrant)" || exit 1
toolbox_cid="$(require_service_container toolbox)" || exit 1

wait_for_container_ready "${qdrant_cid}" 180 || fail "qdrant is not ready"
wait_for_container_ready "${toolbox_cid}" 60 || fail "toolbox is not ready"

published_6333="$(docker port "${qdrant_cid}" 6333/tcp 2>/dev/null || true)"
published_6334="$(docker port "${qdrant_cid}" 6334/tcp 2>/dev/null || true)"
[[ -z "${published_6333}" ]] || fail "qdrant port 6333 must not be published on host (got: ${published_6333})"
[[ -z "${published_6334}" ]] || fail "qdrant port 6334 must not be published on host (got: ${published_6334})"
ok "qdrant has no host-published ports"

timeout 30 docker exec "${toolbox_cid}" sh -lc 'curl -fsS http://qdrant:6333/healthz >/dev/null' \
  || fail "qdrant health endpoint is not reachable from internal toolbox"
ok "qdrant health endpoint is reachable from internal network"

expected_storage_dir="${AGENTIC_ROOT:-/srv/agentic}/rag/qdrant"
expected_snapshots_dir="${AGENTIC_ROOT:-/srv/agentic}/rag/qdrant-snapshots"

actual_storage_mount="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/qdrant/storage"}}{{println .Source}}{{end}}{{end}}' "${qdrant_cid}" | head -n 1)"
actual_snapshots_mount="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/qdrant/snapshots"}}{{println .Source}}{{end}}{{end}}' "${qdrant_cid}" | head -n 1)"
qdrant_init_file_path="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${qdrant_cid}" | sed -n 's/^QDRANT_INIT_FILE_PATH=//p' | head -n 1)"

[[ -n "${actual_storage_mount}" ]] || fail "missing /qdrant/storage writable mount"
[[ -n "${actual_snapshots_mount}" ]] || fail "missing /qdrant/snapshots writable mount"

expected_storage_dir="$(readlink -f "${expected_storage_dir}" 2>/dev/null || printf '%s' "${expected_storage_dir}")"
expected_snapshots_dir="$(readlink -f "${expected_snapshots_dir}" 2>/dev/null || printf '%s' "${expected_snapshots_dir}")"
actual_storage_mount="$(readlink -f "${actual_storage_mount}" 2>/dev/null || printf '%s' "${actual_storage_mount}")"
actual_snapshots_mount="$(readlink -f "${actual_snapshots_mount}" 2>/dev/null || printf '%s' "${actual_snapshots_mount}")"

[[ "${actual_storage_mount}" == "${expected_storage_dir}" ]] \
  || fail "qdrant storage mount source mismatch (expected=${expected_storage_dir}, actual=${actual_storage_mount})"
[[ "${actual_snapshots_mount}" == "${expected_snapshots_dir}" ]] \
  || fail "qdrant snapshots mount source mismatch (expected=${expected_snapshots_dir}, actual=${actual_snapshots_mount})"
[[ "${qdrant_init_file_path}" == "/qdrant/storage/.qdrant-initialized" ]] \
  || fail "unexpected QDRANT_INIT_FILE_PATH (expected=/qdrant/storage/.qdrant-initialized, actual=${qdrant_init_file_path:-unset})"
ok "qdrant storage and snapshots mounts are configured"

ok "J1_qdrant passed"
