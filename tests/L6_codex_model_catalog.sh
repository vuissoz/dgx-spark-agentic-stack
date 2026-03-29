#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L6 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd timeout
assert_cmd python3

default_model="${AGENTIC_DEFAULT_MODEL:-${OLLAMA_PRELOAD_GENERATE_MODEL:-nemotron-cascade-2:30b}}"
expected_context_window="${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-50909}"
expected_soft_threshold="${AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS:-38181}"
expected_danger_threshold="${AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS:-45818}"
exec_timeout="${AGENTIC_CODEX_MODEL_SMOKE_TIMEOUT_SECONDS:-240}"
prompt_text="${AGENTIC_CODEX_MODEL_SMOKE_PROMPT:-Reply with exactly: codex-local-model-ok}"

runtime_env_file="${AGENTIC_ROOT:-/srv/agentic}/deployments/runtime.env"
if [[ -f "${runtime_env_file}" ]]; then
  runtime_value="$(sed -n 's/^AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW=//p' "${runtime_env_file}" | head -n 1)"
  if [[ -n "${runtime_value}" ]]; then
    expected_context_window="${runtime_value}"
  fi
  runtime_value="$(sed -n 's/^AGENTIC_CONTEXT_COMPACTION_SOFT_TOKENS=//p' "${runtime_env_file}" | head -n 1)"
  if [[ -n "${runtime_value}" ]]; then
    expected_soft_threshold="${runtime_value}"
  fi
  runtime_value="$(sed -n 's/^AGENTIC_CONTEXT_COMPACTION_DANGER_TOKENS=//p' "${runtime_env_file}" | head -n 1)"
  if [[ -n "${runtime_value}" ]]; then
    expected_danger_threshold="${runtime_value}"
  fi
fi

codex_cid="$(require_service_container agentic-codex)" || exit 1
gate_cid="$(require_service_container ollama-gate)" || exit 1

wait_for_container_ready "${codex_cid}" 120 || fail "agentic-codex is not ready"
wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate is not ready"

config_file="$(mktemp)"
catalog_file="$(mktemp)"
exec_out="$(mktemp)"
exec_err="$(mktemp)"
trap 'rm -f "${config_file}" "${catalog_file}" "${exec_out}" "${exec_err}"' EXIT

docker exec "${codex_cid}" sh -lc 'cat /state/home/.codex/config.toml' >"${config_file}" \
  || fail "unable to read codex config from agentic-codex"

catalog_path="$(python3 - "${config_file}" <<'PY'
import pathlib
import sys
import tomllib

config_path = pathlib.Path(sys.argv[1])
with config_path.open('rb') as fh:
    cfg = tomllib.load(fh)

model = cfg.get('model')
provider = cfg.get('model_provider')
catalog = cfg.get('model_catalog_json')
providers = cfg.get('model_providers') or {}
ollama_gate = providers.get('ollama_gate') or {}

if not model:
    raise SystemExit('missing top-level model in codex config')
if provider != 'ollama_gate':
    raise SystemExit(f"unexpected model_provider: {provider!r}")
if not catalog:
    raise SystemExit('missing model_catalog_json in codex config')
if ollama_gate.get('wire_api') != 'responses':
    raise SystemExit('unexpected wire_api for model_providers.ollama_gate')
if not ollama_gate.get('base_url'):
    raise SystemExit('missing base_url for model_providers.ollama_gate')

print(catalog)
PY
)" || fail "codex config validation failed"

grep -q "^model = \"${default_model}\"$" "${config_file}" \
  || fail "codex config model does not match AGENTIC_DEFAULT_MODEL (${default_model})"
ok "agentic-codex config exposes managed model/provider/catalog settings"

docker exec "${codex_cid}" sh -lc "cat '${catalog_path}'" >"${catalog_file}" \
  || fail "unable to read codex model catalog at ${catalog_path}"

python3 - "${catalog_file}" "${default_model}" "${expected_context_window}" "${expected_soft_threshold}" "${expected_danger_threshold}" <<'PY'
import json
import pathlib
import sys

catalog_path = pathlib.Path(sys.argv[1])
default_model = sys.argv[2]
expected_context_window = int(sys.argv[3])
expected_soft_threshold = int(sys.argv[4])
expected_danger_threshold = int(sys.argv[5])

with catalog_path.open('r', encoding='utf-8') as fh:
    payload = json.load(fh)

models = payload.get('models')
if not isinstance(models, list) or not models:
    raise SystemExit('catalog models[] is missing or empty')

slugs = [m.get('slug') for m in models if isinstance(m, dict)]
if default_model not in slugs:
    raise SystemExit(f"default model {default_model!r} not present in catalog slugs={slugs!r}")

target = next(m for m in models if isinstance(m, dict) and m.get('slug') == default_model)
if target.get('context_window') != expected_context_window:
    raise SystemExit(
        f"unexpected context_window={target.get('context_window')!r} expected={expected_context_window}"
    )
if target.get('auto_compact_token_limit') != expected_soft_threshold:
    raise SystemExit(
        "unexpected auto_compact_token_limit="
        f"{target.get('auto_compact_token_limit')!r} expected={expected_soft_threshold}"
    )

base_instructions = target.get('base_instructions')
if not isinstance(base_instructions, str):
    raise SystemExit('catalog base_instructions is missing')
for threshold in (expected_soft_threshold, expected_danger_threshold):
    if str(threshold) not in base_instructions:
        raise SystemExit(f"base_instructions missing compaction threshold {threshold}")
PY
ok "codex model catalog contains default model '${default_model}' with managed compaction policy"

set +e
timeout "${exec_timeout}" docker exec "${codex_cid}" sh -lc \
  "cd /workspace && codex exec --skip-git-repo-check --json --color never '${prompt_text}'" \
  >"${exec_out}" 2>"${exec_err}"
rc=$?
set -e

if [[ "${rc}" -ne 0 ]]; then
  cat "${exec_out}" >&2 || true
  cat "${exec_err}" >&2 || true
  fail "codex exec smoke failed (exit=${rc})"
fi

if grep -Eqi 'Model metadata for `?.*`? not found|fallback metadata' "${exec_out}" "${exec_err}"; then
  cat "${exec_out}" >&2 || true
  cat "${exec_err}" >&2 || true
  fail "codex exec still reports fallback model metadata"
fi

[[ -s "${exec_out}" ]] || fail "codex exec smoke produced empty output"
ok "codex exec runs on local model '${default_model}' without fallback-metadata warning"

ok "L6_codex_model_catalog passed"
