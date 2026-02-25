#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L5 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd curl
assert_cmd timeout
assert_cmd python3

default_model="${AGENTIC_DEFAULT_MODEL:-${OLLAMA_PRELOAD_GENERATE_MODEL:-llama3.1:8b}}"
prompt_text="${AGENTIC_DEFAULT_MODEL_SMOKE_PROMPT:-hello}"
http_timeout="${AGENTIC_DEFAULT_MODEL_SMOKE_TIMEOUT_SECONDS:-180}"

assert_json_response_non_empty() {
  local payload_file="$1"
  local context="$2"

  python3 - "${payload_file}" "${context}" <<'PY'
import json
import sys

payload_path = sys.argv[1]
context = sys.argv[2]

with open(payload_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

response = str(payload.get("response", "")).strip()
if not response:
    raise SystemExit(f"{context}: empty response field")
PY
}

assert_model_list_contains() {
  local payload_file="$1"
  local model="$2"
  local context="$3"

  python3 - "${payload_file}" "${model}" "${context}" <<'PY'
import json
import sys

payload_path = sys.argv[1]
model = sys.argv[2]
context = sys.argv[3]

with open(payload_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

models = payload.get("models")
if not isinstance(models, list):
    raise SystemExit(f"{context}: missing models[] field")

names = [item.get("name") for item in models if isinstance(item, dict)]
if model not in names:
    raise SystemExit(f"{context}: model '{model}' not found in tags ({names})")
PY
}

call_generate_host() {
  local endpoint="$1"
  local out_file="$2"

  local payload
  payload="$(printf '{"model":"%s","prompt":"%s","stream":false}' "${default_model}" "${prompt_text}")"

  local http_code
  http_code="$(
    timeout "$((http_timeout + 5))" \
      curl -sS -o "${out_file}" -w '%{http_code}' \
      --max-time "${http_timeout}" \
      -H 'Content-Type: application/json' \
      -d "${payload}" \
      "${endpoint}/api/generate"
  )"

  [[ "${http_code}" == "200" ]] || {
    cat "${out_file}" >&2 || true
    fail "${endpoint}/api/generate returned HTTP ${http_code}"
  }
}

call_generate_container_python() {
  local container_id="$1"
  local endpoint="$2"
  local out_file="$3"

  timeout "$((http_timeout + 15))" docker exec -i "${container_id}" \
    python3 - "${endpoint}" "${default_model}" "${prompt_text}" "${http_timeout}" >"${out_file}" <<'PY'
import json
import sys
import urllib.request

endpoint = sys.argv[1].rstrip("/")
model = sys.argv[2]
prompt = sys.argv[3]
timeout_seconds = int(sys.argv[4])

payload = {
    "model": model,
    "prompt": prompt,
    "stream": False,
}

req = urllib.request.Request(
    f"{endpoint}/api/generate",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)

with urllib.request.urlopen(req, timeout=timeout_seconds) as resp:
    if resp.status != 200:
        raise SystemExit(f"HTTP status {resp.status}")
    sys.stdout.write(resp.read().decode("utf-8"))
PY
}

call_generate_container_curl() {
  local container_id="$1"
  local endpoint="$2"
  local out_file="$3"

  local payload
  payload="$(printf '{"model":"%s","prompt":"%s","stream":false}' "${default_model}" "${prompt_text}")"

  timeout "$((http_timeout + 10))" docker exec "${container_id}" \
    sh -lc "curl -sS --max-time ${http_timeout} -H 'Content-Type: application/json' -d '${payload}' '${endpoint}/api/generate'" >"${out_file}"
}

ollama_cid="$(require_service_container ollama)" || exit 1
gate_cid="$(require_service_container ollama-gate)" || exit 1
toolbox_cid="$(require_service_container toolbox)" || exit 1
claude_cid="$(require_service_container agentic-claude)" || exit 1
codex_cid="$(require_service_container agentic-codex)" || exit 1
opencode_cid="$(require_service_container agentic-opencode)" || exit 1
vibestral_cid="$(require_service_container agentic-vibestral)" || exit 1
openwebui_cid="$(require_service_container openwebui)" || exit 1
openhands_cid="$(require_service_container openhands)" || exit 1

wait_for_container_ready "${ollama_cid}" 180 || fail "ollama is not ready"
wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate is not ready"
wait_for_container_ready "${toolbox_cid}" 60 || fail "toolbox is not ready"
wait_for_container_ready "${claude_cid}" 90 || fail "agentic-claude is not ready"
wait_for_container_ready "${codex_cid}" 90 || fail "agentic-codex is not ready"
wait_for_container_ready "${opencode_cid}" 90 || fail "agentic-opencode is not ready"
wait_for_container_ready "${vibestral_cid}" 90 || fail "agentic-vibestral is not ready"
wait_for_container_ready "${openwebui_cid}" 120 || fail "openwebui is not ready"
wait_for_container_ready "${openhands_cid}" 120 || fail "openhands is not ready"

host_tags_file="$(mktemp)"
gate_tags_file="$(mktemp)"
ollama_response_file="$(mktemp)"
gate_response_file="$(mktemp)"
claude_response_file="$(mktemp)"
codex_response_file="$(mktemp)"
opencode_response_file="$(mktemp)"
vibestral_response_file="$(mktemp)"
openwebui_response_file="$(mktemp)"
openhands_response_file="$(mktemp)"
trap 'rm -f "${host_tags_file}" "${gate_tags_file}" "${ollama_response_file}" "${gate_response_file}" "${claude_response_file}" "${codex_response_file}" "${opencode_response_file}" "${vibestral_response_file}" "${openwebui_response_file}" "${openhands_response_file}"' EXIT

curl -fsS --max-time 20 http://127.0.0.1:11434/api/tags >"${host_tags_file}"
assert_model_list_contains "${host_tags_file}" "${default_model}" "ollama host /api/tags" \
  || fail "default model '${default_model}' is not preloaded in ollama"
ok "default model '${default_model}' is present in ollama /api/tags"

call_generate_host "http://127.0.0.1:11434" "${ollama_response_file}"
assert_json_response_non_empty "${ollama_response_file}" "ollama host /api/generate" \
  || fail "ollama host call returned empty response"
ok "ollama host /api/generate answered prompt '${prompt_text}'"

# Validate both model visibility and generation through the gate path.
timeout "$((http_timeout + 10))" docker exec "${toolbox_cid}" \
  sh -lc "curl -sS --max-time ${http_timeout} http://ollama-gate:11435/api/tags" >"${gate_tags_file}"
assert_model_list_contains "${gate_tags_file}" "${default_model}" "ollama-gate /api/tags via toolbox" \
  || fail "default model '${default_model}' is not visible through ollama-gate"
ok "default model '${default_model}' is visible via ollama-gate /api/tags"

call_generate_container_curl "${toolbox_cid}" "http://ollama-gate:11435" "${gate_response_file}"
assert_json_response_non_empty "${gate_response_file}" "ollama-gate /api/generate via toolbox" \
  || fail "ollama-gate generate call returned empty response"
ok "ollama-gate /api/generate answered prompt '${prompt_text}'"

call_generate_container_python "${claude_cid}" "http://ollama-gate:11435" "${claude_response_file}"
assert_json_response_non_empty "${claude_response_file}" "agentic-claude -> ollama-gate" \
  || fail "agentic-claude model call returned empty response"
ok "agentic-claude model call succeeded"

call_generate_container_python "${codex_cid}" "http://ollama-gate:11435" "${codex_response_file}"
assert_json_response_non_empty "${codex_response_file}" "agentic-codex -> ollama-gate" \
  || fail "agentic-codex model call returned empty response"
ok "agentic-codex model call succeeded"

call_generate_container_python "${opencode_cid}" "http://ollama-gate:11435" "${opencode_response_file}"
assert_json_response_non_empty "${opencode_response_file}" "agentic-opencode -> ollama-gate" \
  || fail "agentic-opencode model call returned empty response"
ok "agentic-opencode model call succeeded"

call_generate_container_python "${vibestral_cid}" "http://ollama-gate:11435" "${vibestral_response_file}"
assert_json_response_non_empty "${vibestral_response_file}" "agentic-vibestral -> ollama-gate" \
  || fail "agentic-vibestral model call returned empty response"
ok "agentic-vibestral model call succeeded"

call_generate_container_python "${openwebui_cid}" "http://ollama-gate:11435" "${openwebui_response_file}"
assert_json_response_non_empty "${openwebui_response_file}" "openwebui -> ollama-gate" \
  || fail "openwebui model call returned empty response"
ok "openwebui model call succeeded"

call_generate_container_python "${openhands_cid}" "http://ollama-gate:11435" "${openhands_response_file}"
assert_json_response_non_empty "${openhands_response_file}" "openhands -> ollama-gate" \
  || fail "openhands model call returned empty response"
ok "openhands model call succeeded"

ok "L5_default_model_e2e passed"
