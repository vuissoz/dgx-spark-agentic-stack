#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_D_TESTS:-0}" == "1" ]]; then
  ok "D9 skipped because AGENTIC_SKIP_D_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd python3

toolbox_cid="$(require_service_container toolbox)" || exit 1
gate_cid="$(require_service_container ollama-gate)" || exit 1
wait_for_container_ready "${toolbox_cid}" 30 || fail "toolbox is not ready"
wait_for_container_ready "${gate_cid}" 90 || fail "ollama-gate is not ready"

extract_code() {
  printf '%s\n' "$1" | tail -n 1 | tr -d '\r'
}

extract_body() {
  printf '%s\n' "$1" | sed '$d'
}

models_resp="$(timeout 45 docker exec "${toolbox_cid}" sh -lc \
  "curl -sS -H 'X-Agent-Project: d9' -H 'X-Agent-Session: d9-v1-models-$$' -H 'X-Gate-Queue-Timeout-Seconds: 25' http://ollama-gate:11435/v1/models -w '\n%{http_code}'")"
models_code="$(extract_code "${models_resp}")"
models_body="$(extract_body "${models_resp}")"
[[ "${models_code}" == "200" ]] || fail "/v1/models returned status ${models_code}"

tags_resp="$(timeout 45 docker exec "${toolbox_cid}" sh -lc \
  "curl -sS -H 'X-Agent-Project: d9' -H 'X-Agent-Session: d9-api-tags-$$' -H 'X-Gate-Queue-Timeout-Seconds: 25' http://ollama-gate:11435/api/tags -w '\n%{http_code}'")"
tags_code="$(extract_code "${tags_resp}")"
tags_body="$(extract_body "${tags_resp}")"
[[ "${tags_code}" == "200" ]] || fail "/api/tags returned status ${tags_code}"

models_file="$(mktemp)"
tags_file="$(mktemp)"
trap 'rm -f "${models_file}" "${tags_file}"' EXIT
printf '%s\n' "${models_body}" >"${models_file}"
printf '%s\n' "${tags_body}" >"${tags_file}"

default_model="${AGENTIC_DEFAULT_MODEL:-llama3.1:8b}"

python3 - "${models_file}" "${tags_file}" "${default_model}" <<'PY'
import json
import sys

models_path = sys.argv[1]
tags_path = sys.argv[2]
preferred_model = sys.argv[3]

with open(models_path, "r", encoding="utf-8") as fh:
    models_payload = json.load(fh)
with open(tags_path, "r", encoding="utf-8") as fh:
    tags_payload = json.load(fh)

assert models_payload.get("object") == "list", models_payload
data = models_payload.get("data")
assert isinstance(data, list) and data, models_payload

model_map: dict[str, dict] = {}
metadata_count = 0
for item in data:
    assert isinstance(item, dict), item
    model_id = item.get("id")
    assert isinstance(model_id, str) and model_id, item
    assert item.get("object") == "model", item
    owned_by = item.get("owned_by")
    assert isinstance(owned_by, str) and owned_by, item
    metadata = item.get("metadata")
    if isinstance(metadata, dict):
        metadata_count += 1
    model_map[model_id] = item

assert metadata_count > 0, "no model includes metadata in /v1/models payload"

tags = tags_payload.get("models")
assert isinstance(tags, list) and tags, tags_payload
tags_map: dict[str, dict] = {}
for entry in tags:
    if not isinstance(entry, dict):
        continue
    name = entry.get("name")
    if isinstance(name, str) and name:
        tags_map[name] = entry

common_models = sorted(set(model_map) & set(tags_map))
assert common_models, "no overlapping model ids between /v1/models and /api/tags"
selected = preferred_model if preferred_model in common_models else common_models[0]

record = model_map[selected]
metadata = record.get("metadata")
assert isinstance(metadata, dict), record
assert metadata.get("source") == "ollama:/api/tags", metadata
assert metadata.get("backend") == "ollama", metadata
assert metadata.get("provider") == "local", metadata

tag_entry = tags_map[selected]
digest = tag_entry.get("digest")
if isinstance(digest, str) and digest:
    assert metadata.get("digest") == digest, (metadata, tag_entry)
size = tag_entry.get("size")
if isinstance(size, int) and size >= 0:
    assert metadata.get("size_bytes") == size, (metadata, tag_entry)
modified_at = tag_entry.get("modified_at")
if isinstance(modified_at, str) and modified_at:
    assert metadata.get("modified_at") == modified_at, (metadata, tag_entry)
details = tag_entry.get("details")
if isinstance(details, dict):
    family = details.get("family")
    if isinstance(family, str) and family:
        assert metadata.get("family") == family, (metadata, details)
PY

ok "gate /v1/models keeps base OpenAI-compatible fields"
ok "gate /v1/models includes enriched metadata sourced from /api/tags"
ok "D9_gate_models_metadata passed"
