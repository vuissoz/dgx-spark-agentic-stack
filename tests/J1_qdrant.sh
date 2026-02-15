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

ok "J1_qdrant passed"
