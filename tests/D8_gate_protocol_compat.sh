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

assert_responses_tool_call_payload() {
  local body_file="$1"
  local expected_tool="$2"
  python3 - "${body_file}" "${expected_tool}" <<'PY'
import json
import sys

path = sys.argv[1]
expected_tool = sys.argv[2]
with open(path, 'r', encoding='utf-8') as fh:
    payload = json.load(fh)
assert payload.get('object') == 'response', payload
assert payload.get('finish_reason') == 'tool_calls', payload
output = payload.get('output')
assert isinstance(output, list) and output, payload
tool_calls = [item for item in output if isinstance(item, dict) and item.get('type') == 'function_call']
assert tool_calls, payload
first = tool_calls[0]
assert first.get('name') == expected_tool, payload
call_id = first.get('call_id')
assert isinstance(call_id, str) and call_id.strip(), payload
arguments = first.get('arguments')
assert isinstance(arguments, str) and arguments.strip(), payload
parsed_args = json.loads(arguments)
assert isinstance(parsed_args, dict), payload
usage = payload.get('usage')
assert isinstance(usage, dict), payload
for key in ('input_tokens', 'output_tokens', 'total_tokens'):
    assert isinstance(usage.get(key), int) and usage[key] >= 0, payload
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

assert_anthropic_tool_use_payload() {
  local body_file="$1"
  local expected_tool="$2"
  python3 - "${body_file}" "${expected_tool}" <<'PY'
import json
import sys

path = sys.argv[1]
expected_tool = sys.argv[2]
with open(path, 'r', encoding='utf-8') as fh:
    payload = json.load(fh)
assert payload.get('type') == 'message', payload
assert payload.get('role') == 'assistant', payload
assert payload.get('stop_reason') == 'tool_use', payload
content = payload.get('content')
assert isinstance(content, list) and content, payload
tool_items = [item for item in content if isinstance(item, dict) and item.get('type') == 'tool_use']
assert tool_items, payload
first = tool_items[0]
assert first.get('name') == expected_tool, payload
tool_id = first.get('id')
assert isinstance(tool_id, str) and tool_id.strip(), payload
tool_input = first.get('input')
assert isinstance(tool_input, dict), payload
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

chat_stream_payload="$(python3 - <<PY
import json
print(json.dumps({
    'model': '${default_model}',
    'stream': True,
    'messages': [
        {'role': 'user', 'content': 'D8 chat stream compatibility check'}
    ],
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

responses_tool_payload="$(python3 - <<PY
import json
print(json.dumps({
    'model': '${default_model}',
    'input': [
        {
            'role': 'user',
            'content': [
                {'type': 'input_text', 'text': 'Use tool get_weather for city Paris and return no prose.'}
            ],
        }
    ],
    'tools': [
        {
            'type': 'function',
            'function': {
                'name': 'get_weather',
                'description': 'Get weather by city',
                'parameters': {
                    'type': 'object',
                    'properties': {'city': {'type': 'string'}},
                    'required': ['city'],
                },
            },
        }
    ],
    'tool_choice': {'type': 'function', 'function': {'name': 'get_weather'}},
    'temperature': 0,
}))
PY
)"

responses_tool_codex_schema_payload="$(python3 - <<PY
import json
print(json.dumps({
    'model': '${default_model}',
    'input': [
        {
            'role': 'user',
            'content': [
                {'type': 'input_text', 'text': 'Use tool exec_command to print working directory and return no prose.'}
            ],
        }
    ],
    'tools': [
        {
            'type': 'function',
            'name': 'exec_command',
            'description': 'Run a shell command and return output',
            'parameters': {
                'type': 'object',
                'properties': {'cmd': {'type': 'string'}},
                'required': ['cmd'],
            },
        }
    ],
    'tool_choice': {'type': 'function', 'function': {'name': 'exec_command'}},
    'temperature': 0,
}))
PY
)"

responses_tool_stream_payload="$(python3 - <<PY
import json
print(json.dumps({
    'model': '${default_model}',
    'input': [
        {
            'role': 'user',
            'content': [
                {'type': 'input_text', 'text': 'Use tool get_weather for city Paris and return no prose.'}
            ],
        }
    ],
    'tools': [
        {
            'type': 'function',
            'function': {
                'name': 'get_weather',
                'description': 'Get weather by city',
                'parameters': {
                    'type': 'object',
                    'properties': {'city': {'type': 'string'}},
                    'required': ['city'],
                },
            },
        }
    ],
    'tool_choice': {'type': 'function', 'function': {'name': 'get_weather'}},
    'temperature': 0,
    'stream': True,
}))
PY
)"

messages_tool_payload="$(python3 - <<PY
import json
print(json.dumps({
    'model': '${default_model}',
    'max_tokens': 256,
    'messages': [
        {
            'role': 'user',
            'content': [
                {'type': 'text', 'text': 'Use tool get_weather for city Paris and return no prose.'}
            ],
        }
    ],
    'tools': [
        {
            'name': 'get_weather',
            'description': 'Get weather by city',
            'input_schema': {
                'type': 'object',
                'properties': {'city': {'type': 'string'}},
                'required': ['city'],
            },
        }
    ],
    'tool_choice': {'type': 'tool', 'name': 'get_weather'},
    'temperature': 0,
}))
PY
)"

resp_file="$(mktemp)"
msg_file="$(mktemp)"
stream_file="$(mktemp)"
chat_stream_file="$(mktemp)"
resp_tool_file="$(mktemp)"
resp_tool_codex_schema_file="$(mktemp)"
resp_tool_stream_file="$(mktemp)"
msg_tool_file="$(mktemp)"
resp_roundtrip_file="$(mktemp)"
msg_roundtrip_file="$(mktemp)"
trap 'rm -f "${resp_file}" "${msg_file}" "${stream_file}" "${chat_stream_file}" "${resp_tool_file}" "${resp_tool_codex_schema_file}" "${resp_tool_stream_file}" "${msg_tool_file}" "${resp_roundtrip_file}" "${msg_roundtrip_file}"' EXIT

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

chat_stream_resp="$(call_post "d8-v1-chat-stream-$$" "http://ollama-gate:11435/v1/chat/completions" "${chat_stream_payload}")"
chat_stream_code="$(extract_code "${chat_stream_resp}")"
chat_stream_body="$(extract_body "${chat_stream_resp}")"
printf '%s\n' "${chat_stream_body}" >"${chat_stream_file}"
[[ "${chat_stream_code}" == "200" ]] || {
  cat "${chat_stream_file}" >&2
  fail "/v1/chat/completions stream returned status ${chat_stream_code}"
}
grep -q '^data: {' "${chat_stream_file}" || fail "/v1/chat/completions stream missing JSON data frames"
grep -q '^data: \[DONE\]$' "${chat_stream_file}" || fail "/v1/chat/completions stream missing [DONE] terminator"
python3 - "${chat_stream_file}" <<'PY'
import json
import sys

path = sys.argv[1]
delta_content_seen = False
finish_reason_seen = False
done_seen = False
with open(path, 'r', encoding='utf-8') as fh:
    for line in fh:
        stripped = line.strip()
        if stripped == 'data: [DONE]':
            done_seen = True
            continue
        if not stripped.startswith('data: '):
            continue
        payload = stripped[len('data: '):]
        if not payload:
            continue
        obj = json.loads(payload)
        assert obj.get('object') == 'chat.completion.chunk', obj
        choices = obj.get('choices')
        assert isinstance(choices, list) and choices, obj
        first = choices[0]
        assert isinstance(first, dict), obj
        delta = first.get('delta')
        assert isinstance(delta, dict), obj
        if isinstance(delta.get('content'), str) and delta['content'].strip():
            delta_content_seen = True
        if isinstance(first.get('finish_reason'), str):
            finish_reason_seen = True
assert delta_content_seen, 'chat stream did not emit content delta'
assert finish_reason_seen, 'chat stream did not emit terminal finish_reason chunk'
assert done_seen, 'chat stream did not emit [DONE] marker'
PY
ok "gate /v1/chat/completions streaming compatibility is operational"

responses_tool_resp="$(call_post "d8-v1-responses-tool-$$" "http://ollama-gate:11435/v1/responses" "${responses_tool_payload}")"
responses_tool_code="$(extract_code "${responses_tool_resp}")"
responses_tool_body="$(extract_body "${responses_tool_resp}")"
printf '%s\n' "${responses_tool_body}" >"${resp_tool_file}"
[[ "${responses_tool_code}" == "200" ]] || {
  cat "${resp_tool_file}" >&2
  fail "/v1/responses tool-call returned status ${responses_tool_code}"
}
assert_responses_tool_call_payload "${resp_tool_file}" "get_weather" || fail "/v1/responses tool-call payload is invalid"
ok "gate /v1/responses returns function_call output when tool_choice is forced"

responses_tool_codex_schema_resp="$(call_post "d8-v1-responses-tool-codex-schema-$$" "http://ollama-gate:11435/v1/responses" "${responses_tool_codex_schema_payload}")"
responses_tool_codex_schema_code="$(extract_code "${responses_tool_codex_schema_resp}")"
responses_tool_codex_schema_body="$(extract_body "${responses_tool_codex_schema_resp}")"
printf '%s\n' "${responses_tool_codex_schema_body}" >"${resp_tool_codex_schema_file}"
[[ "${responses_tool_codex_schema_code}" == "200" ]] || {
  cat "${resp_tool_codex_schema_file}" >&2
  fail "/v1/responses codex-style tool schema returned status ${responses_tool_codex_schema_code}"
}
assert_responses_tool_call_payload "${resp_tool_codex_schema_file}" "exec_command" \
  || fail "/v1/responses codex-style tool schema payload is invalid"
ok "gate /v1/responses accepts codex-style top-level function tools schema"

responses_tool_stream_resp="$(call_post "d8-v1-responses-tool-stream-$$" "http://ollama-gate:11435/v1/responses" "${responses_tool_stream_payload}")"
responses_tool_stream_code="$(extract_code "${responses_tool_stream_resp}")"
responses_tool_stream_body="$(extract_body "${responses_tool_stream_resp}")"
printf '%s\n' "${responses_tool_stream_body}" >"${resp_tool_stream_file}"
[[ "${responses_tool_stream_code}" == "200" ]] || {
  cat "${resp_tool_stream_file}" >&2
  fail "/v1/responses tool-call stream returned status ${responses_tool_stream_code}"
}
grep -q 'event: response.function_call_arguments.done' "${resp_tool_stream_file}" || fail "/v1/responses stream missing function_call arguments completion event"
python3 - "${resp_tool_stream_file}" <<'PY'
import json
import sys

path = sys.argv[1]
fc_done_seen = False
completed_seen = False
with open(path, 'r', encoding='utf-8') as fh:
    for line in fh:
        if not line.startswith('data: '):
            continue
        payload = line[len('data: '):].strip()
        if payload in ('', '[DONE]'):
            continue
        obj = json.loads(payload)
        event_type = obj.get('type')
        if event_type == 'response.function_call_arguments.done':
            arguments = obj.get('arguments')
            assert isinstance(arguments, str) and arguments.strip(), obj
            parsed = json.loads(arguments)
            assert isinstance(parsed, dict), obj
            fc_done_seen = True
        if event_type == 'response.completed':
            completed_seen = True
            response = obj.get('response') or {}
            output = response.get('output') or []
            tool_items = [item for item in output if isinstance(item, dict) and item.get('type') == 'function_call']
            assert tool_items, obj
assert fc_done_seen, 'response.function_call_arguments.done event not found'
assert completed_seen, 'response.completed event not found'
PY
ok "gate /v1/responses streaming preserves function_call output"

responses_roundtrip_payload="$(python3 - "${resp_tool_file}" "${default_model}" <<'PY'
import json
import sys

path = sys.argv[1]
model = sys.argv[2]
with open(path, 'r', encoding='utf-8') as fh:
    payload = json.load(fh)
call_id = None
for item in payload.get('output', []):
    if isinstance(item, dict) and item.get('type') == 'function_call':
        candidate = item.get('call_id')
        if isinstance(candidate, str) and candidate.strip():
            call_id = candidate.strip()
            break
if not call_id:
    raise SystemExit('missing function_call call_id in /v1/responses tool output')
print(json.dumps({
    'model': model,
    'input': [
        {
            'type': 'function_call_output',
            'call_id': call_id,
            'output': 'weather result: Paris 18C clear sky',
        },
        {
            'role': 'user',
            'content': [{'type': 'input_text', 'text': 'Summarize weather in one short sentence.'}],
        },
    ],
    'temperature': 0,
}))
PY
)"

responses_roundtrip_resp="$(call_post "d8-v1-responses-roundtrip-$$" "http://ollama-gate:11435/v1/responses" "${responses_roundtrip_payload}")"
responses_roundtrip_code="$(extract_code "${responses_roundtrip_resp}")"
responses_roundtrip_body="$(extract_body "${responses_roundtrip_resp}")"
printf '%s\n' "${responses_roundtrip_body}" >"${resp_roundtrip_file}"
[[ "${responses_roundtrip_code}" == "200" ]] || {
  cat "${resp_roundtrip_file}" >&2
  fail "/v1/responses function_call_output round-trip returned status ${responses_roundtrip_code}"
}
assert_response_api_payload "${resp_roundtrip_file}" || fail "/v1/responses function_call_output round-trip payload is invalid"
ok "gate /v1/responses function_call_output round-trip is operational"

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

messages_tool_resp="$(call_post "d8-v1-messages-tool-$$" "http://ollama-gate:11435/v1/messages" "${messages_tool_payload}")"
messages_tool_code="$(extract_code "${messages_tool_resp}")"
messages_tool_body="$(extract_body "${messages_tool_resp}")"
printf '%s\n' "${messages_tool_body}" >"${msg_tool_file}"
[[ "${messages_tool_code}" == "200" ]] || {
  cat "${msg_tool_file}" >&2
  fail "/v1/messages tool-use returned status ${messages_tool_code}"
}
assert_anthropic_tool_use_payload "${msg_tool_file}" "get_weather" || fail "/v1/messages tool-use payload is invalid"
ok "gate /v1/messages returns tool_use content when tool_choice is forced"

messages_roundtrip_payload="$(python3 - "${msg_tool_file}" "${default_model}" <<'PY'
import json
import sys

path = sys.argv[1]
model = sys.argv[2]
with open(path, 'r', encoding='utf-8') as fh:
    payload = json.load(fh)
tool_use_id = None
for item in payload.get('content', []):
    if isinstance(item, dict) and item.get('type') == 'tool_use':
        candidate = item.get('id')
        if isinstance(candidate, str) and candidate.strip():
            tool_use_id = candidate.strip()
            break
if not tool_use_id:
    raise SystemExit('missing tool_use id in /v1/messages tool output')
print(json.dumps({
    'model': model,
    'max_tokens': 256,
    'messages': [
        {
            'role': 'user',
            'content': [
                {
                    'type': 'tool_result',
                    'tool_use_id': tool_use_id,
                    'content': [{'type': 'text', 'text': 'weather result: Paris 18C clear sky'}],
                },
                {'type': 'text', 'text': 'Summarize weather in one short sentence.'},
            ],
        }
    ],
    'temperature': 0,
}))
PY
)"

messages_roundtrip_resp="$(call_post "d8-v1-messages-roundtrip-$$" "http://ollama-gate:11435/v1/messages" "${messages_roundtrip_payload}")"
messages_roundtrip_code="$(extract_code "${messages_roundtrip_resp}")"
messages_roundtrip_body="$(extract_body "${messages_roundtrip_resp}")"
printf '%s\n' "${messages_roundtrip_body}" >"${msg_roundtrip_file}"
[[ "${messages_roundtrip_code}" == "200" ]] || {
  cat "${msg_roundtrip_file}" >&2
  fail "/v1/messages tool_result round-trip returned status ${messages_roundtrip_code}"
}
assert_anthropic_message_payload "${msg_roundtrip_file}" || fail "/v1/messages tool_result round-trip payload is invalid"
ok "gate /v1/messages tool_result round-trip is operational"

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
