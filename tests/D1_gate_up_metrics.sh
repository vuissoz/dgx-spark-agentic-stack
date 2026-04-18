#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_D_TESTS:-0}" == "1" ]]; then
  ok "D1 skipped because AGENTIC_SKIP_D_TESTS=1"
  exit 0
fi

toolbox_cid="$(require_service_container toolbox)"
gate_cid="$(require_service_container ollama-gate)"

wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${gate_cid}" 60 || fail "ollama-gate is not ready"

timeout 12 docker exec "${toolbox_cid}" sh -lc 'curl -fsS http://ollama-gate:11435/metrics | grep -q "queue_depth"' \
  || fail "gate metrics endpoint is unavailable or missing queue_depth"
ok "gate /metrics exposes queue_depth"

models_payload="$(timeout 15 docker exec "${toolbox_cid}" sh -lc 'curl -fsS http://ollama-gate:11435/v1/models')"
printf '%s\n' "${models_payload}" | grep -q '"data"' \
  || fail "gate /v1/models response does not contain data field"
ok "gate /v1/models responds"

tags_payload="$(timeout 15 docker exec "${toolbox_cid}" sh -lc 'curl -fsS http://ollama-gate:11435/api/tags')"
printf '%s\n' "${tags_payload}" | grep -q '"models"' \
  || fail "gate /api/tags response does not contain models field"
ok "gate /api/tags responds with Ollama-compatible payload"

ps_payload="$(timeout 15 docker exec "${toolbox_cid}" sh -lc 'curl -fsS http://ollama-gate:11435/api/ps')"
printf '%s\n' "${ps_payload}" | grep -q '"models"' \
  || fail "gate /api/ps response does not contain models field"
ok "gate /api/ps responds with Ollama-compatible payload"

ok "D1_gate_up_metrics passed"
