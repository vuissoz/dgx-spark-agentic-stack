#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_C_TESTS:-0}" == "1" ]]; then
  ok "C1 skipped because AGENTIC_SKIP_C_TESTS=1"
  exit 0
fi

assert_cmd curl
assert_cmd ss

ollama_cid="$(require_service_container ollama)"
toolbox_cid="$(require_service_container toolbox)"

wait_for_container_ready "${ollama_cid}" 180 || fail "ollama is not ready"
wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"

host_ready=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    host_ready=1
    break
  fi
  sleep 1
done
[[ "${host_ready}" -eq 1 ]] || fail "host endpoint http://127.0.0.1:11434/api/version is unavailable"
ok "host endpoint /api/version is reachable"

listener_lines="$(ss -lntH 2>/dev/null | awk '$4 ~ /:11434$/ { print $4 }')"
[[ -n "${listener_lines}" ]] || fail "no listener found on host port 11434"
while IFS= read -r addr; do
  case "$addr" in
    127.0.0.1:*|[::1]:*)
      ;;
    *)
      fail "ollama host listener is not loopback-only: ${addr}"
      ;;
  esac
done <<< "${listener_lines}"
ok "host listener for 11434 is loopback-only"

timeout 12 docker exec "${toolbox_cid}" sh -lc 'curl -fsS http://ollama:11434/api/version >/dev/null' \
  || fail "internal endpoint http://ollama:11434/api/version is unavailable from toolbox"
ok "internal endpoint /api/version is reachable from toolbox"

health_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${ollama_cid}")"
[[ "${health_status}" == "healthy" ]] || fail "ollama healthcheck is not healthy (actual=${health_status:-none})"
ok "ollama container healthcheck is healthy"

expected_models_dir="${OLLAMA_MODELS_DIR:-${AGENTIC_ROOT:-/srv/agentic}/ollama/models}"
actual_models_mount="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/root/.ollama/models"}}{{println .Source}}{{end}}{{end}}' "${ollama_cid}" | head -n 1)"
[[ -n "${actual_models_mount}" ]] || fail "missing mount for /root/.ollama/models on ollama container"

expected_models_dir="$(readlink -f "${expected_models_dir}" 2>/dev/null || printf '%s' "${expected_models_dir}")"
actual_models_mount="$(readlink -f "${actual_models_mount}" 2>/dev/null || printf '%s' "${actual_models_mount}")"
[[ "${actual_models_mount}" == "${expected_models_dir}" ]] \
  || fail "ollama models mount source mismatch (expected=${expected_models_dir}, actual=${actual_models_mount})"
ok "ollama models mount source matches effective OLLAMA_MODELS_DIR"

ok "C1_ollama_basic passed"
