#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_D_TESTS:-0}" == "1" ]]; then
  ok "D12 skipped because AGENTIC_SKIP_D_TESTS=1"
  exit 0
fi

assert_cmd python3

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

agentic_root="${AGENTIC_ROOT:-/srv/agentic}"
model_routes_file="${agentic_root}/gate/config/model_routes.yml"
mode_file="${agentic_root}/gate/state/llm_mode.json"
backend_file="${agentic_root}/gate/state/llm_backend.json"
backend_runtime_file="${agentic_root}/gate/state/llm_backend_runtime.json"
quota_file="${agentic_root}/gate/state/quotas_state.json"
gate_log="${agentic_root}/gate/logs/gate.jsonl"
openai_key_file="${agentic_root}/secrets/runtime/openai.api_key"
local_switch_cooldown_sec="${AGENTIC_LLM_BACKEND_SWITCH_COOLDOWN_SECONDS:-3}"

[[ -f "${model_routes_file}" ]] || fail "model routes file missing: ${model_routes_file}"
[[ -f "${gate_log}" ]] || fail "gate log file missing: ${gate_log}"

toolbox_cid="$(require_service_container toolbox)"
gate_cid="$(require_service_container ollama-gate)"

wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate is not ready"

refresh_gate_cid() {
  gate_cid="$(require_service_container ollama-gate)"
}

routes_backup="$(mktemp)"
mode_backup="$(mktemp)"
backend_backup="$(mktemp)"
backend_runtime_backup="$(mktemp)"
quota_backup="$(mktemp)"
mode_had_file=0
backend_had_file=0
backend_runtime_had_file=0
quota_had_file=0

cp "${model_routes_file}" "${routes_backup}"
if [[ -f "${mode_file}" ]]; then
  cp "${mode_file}" "${mode_backup}"
  mode_had_file=1
fi
if [[ -f "${backend_file}" ]]; then
  cp "${backend_file}" "${backend_backup}"
  backend_had_file=1
fi
if [[ -f "${backend_runtime_file}" ]]; then
  cp "${backend_runtime_file}" "${backend_runtime_backup}"
  backend_runtime_had_file=1
fi
if [[ -f "${quota_file}" ]]; then
  cp "${quota_file}" "${quota_backup}"
  quota_had_file=1
fi

previous_test_mode="$("${agent_bin}" llm test-mode | awk -F= '{print $2}')"
test_mode_changed=0

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

  if [[ "${backend_had_file}" == "1" ]]; then
    cp "${backend_backup}" "${backend_file}" || true
    chmod 0640 "${backend_file}" || true
  else
    rm -f "${backend_file}" || true
  fi
  rm -f "${backend_backup}" || true

  if [[ "${backend_runtime_had_file}" == "1" ]]; then
    cp "${backend_runtime_backup}" "${backend_runtime_file}" || true
    chmod 0640 "${backend_runtime_file}" || true
  else
    rm -f "${backend_runtime_file}" || true
  fi
  rm -f "${backend_runtime_backup}" || true

  if [[ "${quota_had_file}" == "1" ]]; then
    cp "${quota_backup}" "${quota_file}" || true
    chmod 0640 "${quota_file}" || true
  else
    rm -f "${quota_file}" || true
  fi
  rm -f "${quota_backup}" || true

  if [[ "${test_mode_changed}" == "1" ]]; then
    "${agent_bin}" llm test-mode off >/dev/null 2>&1 || true
  fi

  refresh_gate_cid
  docker restart "${gate_cid}" >/dev/null 2>&1 || true
  wait_for_container_ready "${gate_cid}" 120 || true
}
trap restore EXIT

if [[ "${previous_test_mode}" != "on" ]]; then
  "${agent_bin}" llm test-mode on >/tmp/agent-d12-test-mode.out
  test_mode_changed=1
  refresh_gate_cid
  wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate is not ready after enabling test mode"
fi

install -d -m 0700 "${agentic_root}/secrets/runtime"
if [[ ! -s "${openai_key_file}" ]]; then
  printf 'd12-test-key\n' >"${openai_key_file}"
  chmod 0600 "${openai_key_file}"
fi

rm -f "${quota_file}" || true

python3 - "${model_routes_file}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    """version: 1

defaults:
  backend: ollama

llm:
  default_mode: hybrid

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
  - name: d12-trt
    backend: trtllm
    match:
      - "d12-trt-*"
  - name: d12-openai
    backend: openai
    match:
      - "d12-remote-*"
""",
    encoding="utf-8",
)
PY
chmod 0640 "${model_routes_file}" || true
refresh_gate_cid
docker restart "${gate_cid}" >/dev/null
wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate did not become healthy after D12 route reload"

call_chat() {
  local session="$1"
  local model="$2"
  local tokens="${3:-0}"
  timeout 25 docker exec "${toolbox_cid}" sh -lc "curl -sS -H 'Content-Type: application/json' -H 'X-Agent-Session: ${session}' -H 'X-Agent-Project: d12' -H 'X-Gate-Dry-Run: 1' -H 'X-Gate-Test-Tokens: ${tokens}' -d '{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"d12 mixed routing\"}]}' http://ollama-gate:11435/v1/chat/completions -w '\n%{http_code}'"
}

extract_code() {
  printf '%s\n' "$1" | tail -n 1 | tr -d '\r'
}

extract_body() {
  printf '%s\n' "$1" | sed '$d'
}

assert_log_contains() {
  local session="$1"
  local pattern="$2"
  local line

  line="$(grep "\"session\":\"${session}\"" "${gate_log}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || fail "no gate log entry found for session ${session}"
  printf '%s\n' "${line}" | grep -q "${pattern}" \
    || fail "unexpected gate log content for session ${session} (pattern=${pattern}, line=${line})"
}

mixed_out="$("${agent_bin}" llm mode mixed)"
printf '%s\n' "${mixed_out}" | grep -q 'llm mode set to hybrid' \
  || fail "agent llm mode mixed must canonicalize to hybrid"
current_mode="$("${agent_bin}" llm mode)"
printf '%s\n' "${current_mode}" | grep -q '^llm mode=hybrid$' \
  || fail "agent llm mode must report hybrid after mixed alias"

"${agent_bin}" llm backend both >/tmp/agent-d12-backend-both.out
current_backend="$("${agent_bin}" llm backend)"
printf '%s\n' "${current_backend}" | grep -q '^llm backend=both$' \
  || fail "agent llm backend must report both"

session_local="d12-local-$$"
resp_local="$(call_chat "${session_local}" "d12-local-a")"
code_local="$(extract_code "${resp_local}")"
body_local="$(extract_body "${resp_local}")"
[[ "${code_local}" == "200" ]] || {
  printf '%s\n' "${body_local}" >&2
  fail "hybrid/both must allow default local models"
}
printf '%s\n' "${body_local}" | grep -q 'backend=ollama' \
  || fail "local dry-run response must expose backend=ollama"
assert_log_contains "${session_local}" '"backend":"ollama"'
assert_log_contains "${session_local}" '"llm_mode":"hybrid"'
assert_log_contains "${session_local}" '"llm_backend":"both"'
ok "hybrid+both keeps default local models on ollama"

session_trt_cooldown="d12-trt-cooldown-$$"
resp_trt_cooldown="$(call_chat "${session_trt_cooldown}" "d12-trt-a")"
code_trt_cooldown="$(extract_code "${resp_trt_cooldown}")"
body_trt_cooldown="$(extract_body "${resp_trt_cooldown}")"
[[ "${code_trt_cooldown}" == "429" ]] || {
  printf '%s\n' "${body_trt_cooldown}" >&2
  fail "rapid ollama->trtllm switch must be throttled by anti-thrash cooldown"
}
printf '%s\n' "${body_trt_cooldown}" | grep -q '"type":"backend_switch_cooldown"' \
  || fail "anti-thrash response must expose backend_switch_cooldown"
printf '%s\n' "${body_trt_cooldown}" | grep -q '"current_backend":"ollama"' \
  || fail "anti-thrash response must expose current_backend=ollama"
printf '%s\n' "${body_trt_cooldown}" | grep -q '"target_backend":"trtllm"' \
  || fail "anti-thrash response must expose target_backend=trtllm"
ok "hybrid+both throttles rapid local backend flips"

sleep "${local_switch_cooldown_sec}"

session_trt="d12-trt-$$"
resp_trt="$(call_chat "${session_trt}" "d12-trt-a")"
code_trt="$(extract_code "${resp_trt}")"
body_trt="$(extract_body "${resp_trt}")"
[[ "${code_trt}" == "200" ]] || {
  printf '%s\n' "${body_trt}" >&2
  fail "hybrid/both must allow trtllm-routed local models after cooldown"
}
printf '%s\n' "${body_trt}" | grep -q 'backend=trtllm' \
  || fail "trtllm dry-run response must expose backend=trtllm"
assert_log_contains "${session_trt}" '"backend":"trtllm"'
assert_log_contains "${session_trt}" '"llm_backend":"both"'
assert_log_contains "${session_trt}" '"llm_backend_effective":"trtllm"'
ok "hybrid+both routes trtllm-tagged models to trtllm after cooldown"

session_remote="d12-remote-$$"
resp_remote="$(call_chat "${session_remote}" "d12-remote-a" 1)"
code_remote="$(extract_code "${resp_remote}")"
body_remote="$(extract_body "${resp_remote}")"
[[ "${code_remote}" == "200" ]] || {
  printf '%s\n' "${body_remote}" >&2
  fail "hybrid/both must allow remote-routed models"
}
printf '%s\n' "${body_remote}" | grep -q 'backend=openai' \
  || fail "remote dry-run response must expose backend=openai"
assert_log_contains "${session_remote}" '"backend":"openai"'
assert_log_contains "${session_remote}" '"provider":"openai"'
assert_log_contains "${session_remote}" '"llm_mode":"hybrid"'
assert_log_contains "${session_remote}" '"llm_backend":"both"'
assert_log_contains "${session_remote}" '"llm_backend_effective":"remote"'
ok "hybrid+both routes remote-tagged models to external providers"

"${agent_bin}" llm backend ollama >/tmp/agent-d12-backend-ollama.out
session_trt_blocked="d12-trt-blocked-$$"
resp_trt_blocked="$(call_chat "${session_trt_blocked}" "d12-trt-a")"
code_trt_blocked="$(extract_code "${resp_trt_blocked}")"
body_trt_blocked="$(extract_body "${resp_trt_blocked}")"
[[ "${code_trt_blocked}" == "403" ]] || {
  printf '%s\n' "${body_trt_blocked}" >&2
  fail "llm backend=ollama must block trtllm-routed local models"
}
printf '%s\n' "${body_trt_blocked}" | grep -q '"type":"local_backend_disabled"' \
  || fail "ollama-only rejection must expose local_backend_disabled"
printf '%s\n' "${body_trt_blocked}" | grep -q '"llm_backend":"ollama"' \
  || fail "ollama-only rejection must expose llm_backend=ollama"
ok "llm backend=ollama blocks trtllm-routed models explicitly"

"${agent_bin}" llm backend trtllm >/tmp/agent-d12-backend-trtllm.out
session_ollama_blocked="d12-ollama-blocked-$$"
resp_ollama_blocked="$(call_chat "${session_ollama_blocked}" "d12-local-a")"
code_ollama_blocked="$(extract_code "${resp_ollama_blocked}")"
body_ollama_blocked="$(extract_body "${resp_ollama_blocked}")"
[[ "${code_ollama_blocked}" == "403" ]] || {
  printf '%s\n' "${body_ollama_blocked}" >&2
  fail "llm backend=trtllm must block ollama-routed local models"
}
printf '%s\n' "${body_ollama_blocked}" | grep -q '"type":"local_backend_disabled"' \
  || fail "trtllm-only rejection must expose local_backend_disabled"
printf '%s\n' "${body_ollama_blocked}" | grep -q '"llm_backend":"trtllm"' \
  || fail "trtllm-only rejection must expose llm_backend=trtllm"
ok "llm backend=trtllm blocks ollama-routed models explicitly"

"${agent_bin}" llm mode hybrid >/tmp/agent-d12-hybrid-2.out
"${agent_bin}" llm backend remote >/tmp/agent-d12-backend-remote.out
session_remote_backend_local="d12-remote-backend-local-$$"
resp_remote_backend_local="$(call_chat "${session_remote_backend_local}" "d12-local-a")"
code_remote_backend_local="$(extract_code "${resp_remote_backend_local}")"
body_remote_backend_local="$(extract_body "${resp_remote_backend_local}")"
[[ "${code_remote_backend_local}" == "403" ]] || {
  printf '%s\n' "${body_remote_backend_local}" >&2
  fail "llm backend=remote must block local routed models"
}
printf '%s\n' "${body_remote_backend_local}" | grep -q '"type":"local_backend_disabled"' \
  || fail "remote backend local rejection must expose local_backend_disabled"
printf '%s\n' "${body_remote_backend_local}" | grep -q '"llm_backend":"remote"' \
  || fail "remote backend local rejection must expose llm_backend=remote"
ok "llm backend=remote blocks local backends explicitly"

session_remote_backend_remote="d12-remote-backend-remote-$$"
resp_remote_backend_remote="$(call_chat "${session_remote_backend_remote}" "d12-remote-a" 1)"
code_remote_backend_remote="$(extract_code "${resp_remote_backend_remote}")"
body_remote_backend_remote="$(extract_body "${resp_remote_backend_remote}")"
[[ "${code_remote_backend_remote}" == "200" ]] || {
  printf '%s\n' "${body_remote_backend_remote}" >&2
  fail "llm backend=remote must keep remote-routed models available"
}
printf '%s\n' "${body_remote_backend_remote}" | grep -q 'backend=openai' \
  || fail "remote backend dry-run response must expose backend=openai"
assert_log_contains "${session_remote_backend_remote}" '"backend":"openai"'
assert_log_contains "${session_remote_backend_remote}" '"llm_backend":"remote"'
assert_log_contains "${session_remote_backend_remote}" '"llm_backend_effective":"remote"'
ok "llm backend=remote keeps provider-routed models available"

"${agent_bin}" llm backend both >/tmp/agent-d12-backend-both-2.out
"${agent_bin}" llm mode remote >/tmp/agent-d12-remote-mode.out
session_local_remote_mode="d12-local-remote-mode-$$"
resp_local_remote_mode="$(call_chat "${session_local_remote_mode}" "d12-local-a")"
code_local_remote_mode="$(extract_code "${resp_local_remote_mode}")"
body_local_remote_mode="$(extract_body "${resp_local_remote_mode}")"
[[ "${code_local_remote_mode}" == "403" ]] || {
  printf '%s\n' "${body_local_remote_mode}" >&2
  fail "remote mode must block local backends even when llm backend=both"
}
printf '%s\n' "${body_local_remote_mode}" | grep -q '"reason":"local_backend_disabled_by_mode"' \
  || fail "remote-mode rejection must expose local_backend_disabled_by_mode"
printf '%s\n' "${body_local_remote_mode}" | grep -q '"llm_mode":"remote"' \
  || fail "remote-mode rejection must expose llm_mode=remote"
ok "remote mode blocks local backends independently of backend selector"

session_remote_remote_mode="d12-remote-remote-mode-$$"
resp_remote_remote_mode="$(call_chat "${session_remote_remote_mode}" "d12-remote-a" 1)"
code_remote_remote_mode="$(extract_code "${resp_remote_remote_mode}")"
body_remote_remote_mode="$(extract_body "${resp_remote_remote_mode}")"
[[ "${code_remote_remote_mode}" == "200" ]] || {
  printf '%s\n' "${body_remote_remote_mode}" >&2
  fail "remote mode must keep remote-routed models available"
}
printf '%s\n' "${body_remote_remote_mode}" | grep -q 'backend=openai' \
  || fail "remote-mode dry-run response must still expose backend=openai"
assert_log_contains "${session_remote_remote_mode}" '"backend":"openai"'
assert_log_contains "${session_remote_remote_mode}" '"llm_mode":"remote"'
assert_log_contains "${session_remote_remote_mode}" '"llm_backend":"both"'
ok "remote mode still serves remote-routed models dynamically"

ok "D12_gate_mixed_local_remote_routing passed"
