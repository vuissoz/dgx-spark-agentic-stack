#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_D_TESTS:-0}" == "1" ]]; then
  ok "D8 skipped because AGENTIC_SKIP_D_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd python3

toolbox_cid="$(require_service_container toolbox)" || exit 1
gate_cid="$(require_service_container ollama-gate)" || exit 1
wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${gate_cid}" 90 || fail "ollama-gate is not ready"

default_model="${AGENTIC_DEFAULT_MODEL:-qwen3-coder:30b}"

call_post() {
  local session="$1"
  local url="$2"
  local payload="$3"

  timeout 30 docker exec "${toolbox_cid}" sh -lc \
    "curl -sS -H 'Content-Type: application/json' -H 'X-Agent-Project: d8' -H 'X-Agent-Session: ${session}' -H 'X-Gate-Queue-Timeout-Seconds: 20' -d '${payload}' '${url}' -w '\n%{http_code}'"
}

extract_code() {
  printf '%s\n' "$1" | tail -n 1 | tr -d '\r'
}

extract_body() {
  printf '%s\n' "$1" | sed '$d'
}

assert_response_api_payload() {
  local body_file="$1"
  python3 - "${body_file}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as fh:
    payload = json.load(fh)
assert payload.get('object') == 'response', payload
assert isinstance(payload.get('output_text'), str) and payload['output_text'].strip(), payload
output = payload.get('output')
assert isinstance(output, list) and output, payload
first = output[0]
assert isinstance(first, dict), payload
content = first.get('content')
assert isinstance(content, list) and content, payload
text_item = content[0]
assert isinstance(text_item, dict), payload
assert isinstance(text_item.get('text'), str) and text_item['text'].strip(), payload
usage = payload.get('usage')
assert isinstance(usage, dict), payload
for key in ('input_tokens', 'output_tokens', 'total_tokens'):
    assert isinstance(usage.get(key), int) and usage[key] >= 0, payload
assert usage['total_tokens'] >= usage['input_tokens'], payload
assert usage['total_tokens'] >= usage['output_tokens'], payload
assert usage['total_tokens'] > 0, payload
PY
}

assert_anthropic_message_payload() {
  local body_file="$1"
  python3 - "${body_file}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as fh:
    payload = json.load(fh)
assert payload.get('type') == 'message', payload
assert payload.get('role') == 'assistant', payload
content = payload.get('content')
assert isinstance(content, list) and content, payload
first = content[0]
assert isinstance(first, dict), payload
assert first.get('type') == 'text', payload
text = first.get('text')
assert isinstance(text, str) and text.strip(), payload
usage = payload.get('usage')
assert isinstance(usage, dict), payload
for key in ('input_tokens', 'output_tokens'):
    assert isinstance(usage.get(key), int) and usage[key] >= 0, payload
assert usage['input_tokens'] + usage['output_tokens'] > 0, payload
PY
}

responses_payload="$(python3 - <<PY
import json
print(json.dumps({
    'model': '${default_model}',
    'input': 'D8 responses compatibility check',
}))
PY
)"

messages_payload="$(python3 - <<PY
import json
print(json.dumps({
    'model': '${default_model}',
    'max_tokens': 256,
    'messages': [
        {'role': 'user', 'content': 'D8 messages compatibility check'}
    ],
}))
PY
)"

messages_stream_payload="$(python3 - <<PY
import json
print(json.dumps({
    'model': '${default_model}',
    'max_tokens': 256,
    'stream': True,
    'messages': [
        {'role': 'user', 'content': 'D8 stream compatibility check'}
    ],
}))
PY
)"

resp_file="$(mktemp)"
msg_file="$(mktemp)"
stream_file="$(mktemp)"
trap 'rm -f "${resp_file}" "${msg_file}" "${stream_file}"' EXIT

responses_resp="$(call_post "d8-v1-responses-$$" "http://ollama-gate:11435/v1/responses" "${responses_payload}")"
responses_code="$(extract_code "${responses_resp}")"
responses_body="$(extract_body "${responses_resp}")"
printf '%s\n' "${responses_body}" >"${resp_file}"
[[ "${responses_code}" == "200" ]] || {
  cat "${resp_file}" >&2
  fail "/v1/responses returned status ${responses_code}"
}
assert_response_api_payload "${resp_file}" || fail "/v1/responses payload does not match expected compatibility schema"
ok "gate /v1/responses compatibility endpoint is operational"

responses_alias_resp="$(call_post "d8-responses-alias-$$" "http://ollama-gate:11435/responses" "${responses_payload}")"
responses_alias_code="$(extract_code "${responses_alias_resp}")"
[[ "${responses_alias_code}" == "200" ]] || fail "/responses alias returned status ${responses_alias_code}"
ok "gate /responses alias is operational"

messages_resp="$(call_post "d8-v1-messages-$$" "http://ollama-gate:11435/v1/messages" "${messages_payload}")"
messages_code="$(extract_code "${messages_resp}")"
messages_body="$(extract_body "${messages_resp}")"
printf '%s\n' "${messages_body}" >"${msg_file}"
[[ "${messages_code}" == "200" ]] || {
  cat "${msg_file}" >&2
  fail "/v1/messages returned status ${messages_code}"
}
assert_anthropic_message_payload "${msg_file}" || fail "/v1/messages payload does not match expected compatibility schema"
ok "gate /v1/messages compatibility endpoint is operational"

messages_alias_resp="$(call_post "d8-messages-alias-$$" "http://ollama-gate:11435/messages" "${messages_payload}")"
messages_alias_code="$(extract_code "${messages_alias_resp}")"
[[ "${messages_alias_code}" == "200" ]] || fail "/messages alias returned status ${messages_alias_code}"
ok "gate /messages alias is operational"

messages_stream_resp="$(call_post "d8-v1-messages-stream-$$" "http://ollama-gate:11435/v1/messages" "${messages_stream_payload}")"
messages_stream_code="$(extract_code "${messages_stream_resp}")"
messages_stream_body="$(extract_body "${messages_stream_resp}")"
printf '%s\n' "${messages_stream_body}" >"${stream_file}"
[[ "${messages_stream_code}" == "200" ]] || {
  cat "${stream_file}" >&2
  fail "/v1/messages stream returned status ${messages_stream_code}"
}
grep -q 'event: content_block_delta' "${stream_file}" || fail "/v1/messages stream missing content_block_delta event"
grep -q 'event: message_stop' "${stream_file}" || fail "/v1/messages stream missing message_stop event"
python3 - "${stream_file}" <<'PY'
import json
import sys

path = sys.argv[1]
message_delta_seen = False
usage_seen = False
with open(path, 'r', encoding='utf-8') as fh:
    for line in fh:
        if not line.startswith('data: '):
            continue
        payload = line[len('data: '):].strip()
        if payload in ('', '[DONE]'):
            continue
        obj = json.loads(payload)
        if obj.get('type') != 'message_delta':
            continue
        message_delta_seen = True
        usage = obj.get('usage')
        if isinstance(usage, dict) and isinstance(usage.get('output_tokens'), int):
            if usage['output_tokens'] > 0:
                usage_seen = True
                break
assert message_delta_seen, 'message_delta event not found'
assert usage_seen, 'message_delta usage.output_tokens missing or not positive'
PY
ok "gate /v1/messages streaming compatibility is operational"

ok "D8_gate_protocol_compat passed"
