#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_D_TESTS:-0}" == "1" ]]; then
  ok "D6 skipped because AGENTIC_SKIP_D_TESTS=1"
  exit 0
fi

assert_cmd python3

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
model_routes_file="${agentic_root}/gate/config/model_routes.yml"
mode_file="${agentic_root}/gate/state/llm_mode.json"
quota_file="${agentic_root}/gate/state/quotas_state.json"
gate_log="${agentic_root}/gate/logs/gate.jsonl"
openai_key_file="${agentic_root}/secrets/runtime/openai.api_key"

[[ -f "${model_routes_file}" ]] || fail "model routes file missing: ${model_routes_file}"

toolbox_cid="$(require_service_container toolbox)"
gate_cid="$(require_service_container ollama-gate)"
ollama_cid="$(service_container_id ollama)"
trt_cid="$(service_container_id trtllm)"

wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${gate_cid}" 90 || fail "ollama-gate is not ready"

routes_backup="$(mktemp)"
mode_backup="$(mktemp)"
quota_backup="$(mktemp)"
mode_had_file=0
quota_had_file=0

cp "${model_routes_file}" "${routes_backup}"
if [[ -f "${mode_file}" ]]; then
  cp "${mode_file}" "${mode_backup}"
  mode_had_file=1
fi
if [[ -f "${quota_file}" ]]; then
  cp "${quota_file}" "${quota_backup}"
  quota_had_file=1
fi

ollama_was_running=0
if [[ -n "${ollama_cid}" ]]; then
  if [[ "$(docker inspect --format '{{.State.Status}}' "${ollama_cid}" 2>/dev/null || true)" == "running" ]]; then
    ollama_was_running=1
  fi
fi

trt_was_running=0
if [[ -n "${trt_cid}" ]]; then
  if [[ "$(docker inspect --format '{{.State.Status}}' "${trt_cid}" 2>/dev/null || true)" == "running" ]]; then
    trt_was_running=1
  fi
fi

restore() {
  cp "${routes_backup}" "${model_routes_file}" || true
  chmod 0640 "${model_routes_file}" || true
  rm -f "${routes_backup}" || true

  if [[ "${mode_had_file}" == "1" ]]; then
    cp "${mode_backup}" "${mode_file}" || true
    chmod 0640 "${mode_file}" || true
  else
    rm -f "${mode_file}" || true
  fi
  rm -f "${mode_backup}" || true

  if [[ "${quota_had_file}" == "1" ]]; then
    cp "${quota_backup}" "${quota_file}" || true
    chmod 0640 "${quota_file}" || true
  else
    rm -f "${quota_file}" || true
  fi
  rm -f "${quota_backup}" || true

  if [[ -n "${gate_cid:-}" ]]; then
    docker restart "${gate_cid}" >/dev/null 2>&1 || true
    wait_for_container_ready "${gate_cid}" 120 || true
  fi

  if [[ -n "${ollama_cid:-}" ]]; then
    if [[ "${ollama_was_running}" == "1" ]]; then
      docker start "${ollama_cid}" >/dev/null 2>&1 || true
      wait_for_container_ready "${ollama_cid}" 120 || true
    else
      docker stop "${ollama_cid}" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -n "${trt_cid:-}" ]]; then
    if [[ "${trt_was_running}" == "1" ]]; then
      docker start "${trt_cid}" >/dev/null 2>&1 || true
      wait_for_container_ready "${trt_cid}" 120 || true
    else
      docker stop "${trt_cid}" >/dev/null 2>&1 || true
    fi
  fi
}
trap restore EXIT

cat >"${model_routes_file}" <<'YAML'
version: 1

defaults:
  backend: ollama

llm:
  default_mode: hybrid

quotas:
  providers:
    openai:
      daily_tokens: 3
      monthly_tokens: 10
      daily_requests: 10
      monthly_requests: 20

backends:
  ollama:
    protocol: ollama
    base_url: http://ollama:11434
  trtllm:
    protocol: ollama
    base_url: http://trtllm:11436
  openai:
    protocol: openai
    provider: openai
    base_url: https://api.openai.com/v1
    api_key_file: /gate/secrets/openai.api_key

routes:
  - name: d6-openai
    backend: openai
    match:
      - "d6-remote-*"
YAML
chmod 0640 "${model_routes_file}" || true

install -d -m 0700 "${agentic_root}/secrets/runtime"
if [[ ! -s "${openai_key_file}" ]]; then
  printf 'd6-test-key\n' >"${openai_key_file}"
  chmod 0600 "${openai_key_file}"
fi

docker restart "${gate_cid}" >/dev/null
wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate did not become healthy after D6 route reload"

call_chat() {
  local session="$1"
  local tokens="$2"
  timeout 25 docker exec "${toolbox_cid}" sh -lc "curl -sS -H 'Content-Type: application/json' -H 'X-Agent-Session: ${session}' -H 'X-Agent-Project: d6' -H 'X-Gate-Dry-Run: 1' -H 'X-Gate-Test-Tokens: ${tokens}' -d '{\"model\":\"d6-remote-model\",\"messages\":[{\"role\":\"user\",\"content\":\"d6 quota test\"}]}' http://ollama-gate:11435/v1/chat/completions -w '\n%{http_code}'"
}

extract_code() {
  printf '%s\n' "$1" | tail -n 1 | tr -d '\r'
}

extract_body() {
  printf '%s\n' "$1" | sed '$d'
}

"${agent_bin}" llm mode remote >/tmp/agent-d6-remote.out
if [[ -n "${ollama_cid}" ]]; then
  docker stop "${ollama_cid}" >/dev/null || true
fi
if [[ -n "${trt_cid}" ]]; then
  docker stop "${trt_cid}" >/dev/null || true
fi

remote_session="d6-remote-$$"
remote_resp="$(call_chat "${remote_session}" 1)"
remote_code="$(extract_code "${remote_resp}")"
remote_body="$(extract_body "${remote_resp}")"
[[ "${remote_code}" == "200" ]] || {
  printf '%s\n' "${remote_body}" >&2
  fail "remote mode should allow external provider dry-run even with local backends stopped"
}
ok "remote mode keeps provider-routed requests functional when local backends are stopped"

"${agent_bin}" llm mode local >/tmp/agent-d6-local.out
local_session="d6-local-$$"
local_resp="$(call_chat "${local_session}" 1)"
local_code="$(extract_code "${local_resp}")"
local_body="$(extract_body "${local_resp}")"
[[ "${local_code}" == "403" ]] || {
  printf '%s\n' "${local_body}" >&2
  fail "local mode must block external provider calls explicitly"
}
printf '%s\n' "${local_body}" | grep -q '"type":"external_provider_disabled"' \
  || fail "local mode rejection must expose external_provider_disabled"
printf '%s\n' "${local_body}" | grep -q '"llm_mode":"local"' \
  || fail "local mode rejection must expose llm_mode=local"
ok "local mode blocks provider-routed models explicitly"

rm -f "${quota_file}" || true
docker restart "${gate_cid}" >/dev/null
wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate did not recover after quota reset"
"${agent_bin}" llm mode remote >/tmp/agent-d6-remote2.out

quota_session_a="d6-quota-a-$$"
quota_resp_a="$(call_chat "${quota_session_a}" 2)"
quota_code_a="$(extract_code "${quota_resp_a}")"
quota_body_a="$(extract_body "${quota_resp_a}")"
[[ "${quota_code_a}" == "200" ]] || {
  printf '%s\n' "${quota_body_a}" >&2
  fail "first provider request must pass before hitting quota"
}

quota_session_b="d6-quota-b-$$"
quota_resp_b="$(call_chat "${quota_session_b}" 2)"
quota_code_b="$(extract_code "${quota_resp_b}")"
quota_body_b="$(extract_body "${quota_resp_b}")"
[[ "${quota_code_b}" == "429" ]] || {
  printf '%s\n' "${quota_body_b}" >&2
  fail "second provider request must fail when daily_tokens quota is exceeded"
}
printf '%s\n' "${quota_body_b}" | grep -q '"type":"external_quota_exceeded"' \
  || fail "quota rejection must expose external_quota_exceeded"
printf '%s\n' "${quota_body_b}" | grep -q '"reason":"daily_tokens_quota_exceeded"' \
  || fail "quota rejection must expose daily_tokens_quota_exceeded"
ok "provider token quota is enforced with explicit error details"

[[ -s "${gate_log}" ]] || fail "gate log file missing or empty: ${gate_log}"
log_line="$(grep "\"session\":\"${quota_session_b}\"" "${gate_log}" | tail -n 1 || true)"
[[ -n "${log_line}" ]] || fail "quota-rejected request must be present in gate log"
printf '%s\n' "${log_line}" | grep -q '"reason":"external_quota_exceeded"' \
  || fail "quota-rejected gate log entry must expose external_quota_exceeded reason"

metrics_payload="$(timeout 12 docker exec "${toolbox_cid}" sh -lc 'curl -fsS http://ollama-gate:11435/metrics')"
printf '%s\n' "${metrics_payload}" | grep -q 'external_tokens_total{provider="openai"}' \
  || fail "metrics must expose external_tokens_total for openai"
printf '%s\n' "${metrics_payload}" | grep -q 'external_requests_total{provider="openai"}' \
  || fail "metrics must expose external_requests_total for openai"
printf '%s\n' "${metrics_payload}" | grep -q 'external_quota_remaining{provider="openai",window="daily_tokens"}' \
  || fail "metrics must expose external_quota_remaining daily_tokens for openai"
ok "quota metrics are exposed for alerting"

wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate is unhealthy after quota denials"
for agent_service in agentic-claude agentic-codex agentic-opencode agentic-kilocode; do
  agent_cid="$(service_container_id "${agent_service}")"
  [[ -n "${agent_cid}" ]] || continue
  [[ "$(docker inspect --format '{{.State.Status}}' "${agent_cid}" 2>/dev/null || true)" == "running" ]] \
    || fail "agent service ${agent_service} stopped unexpectedly during quota denials"
done
ok "quota denials do not crash gate or running agent services"

ok "D6_gate_quota_and_local_pause passed"
