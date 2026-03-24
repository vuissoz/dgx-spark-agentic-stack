#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/ollama_context.sh
source "${REPO_ROOT}/scripts/lib/ollama_context.sh"

fixtures_dir="${REPO_ROOT}/tests/fixtures/ollama"
tags_file="${fixtures_dir}/tags.context-estimator.json"
qwen_show_file="${fixtures_dir}/show.qwen3-coder-30b.json"
nemotron_show_file="${fixtures_dir}/show.nemotron-cascade-2-30b.json"

[[ -s "${tags_file}" ]] || fail "missing tags fixture: ${tags_file}"
[[ -s "${qwen_show_file}" ]] || fail "missing qwen show fixture: ${qwen_show_file}"
[[ -s "${nemotron_show_file}" ]] || fail "missing nemotron show fixture: ${nemotron_show_file}"

run_report() {
  local model="$1"
  local requested_context="$2"
  local mem_limit="$3"
  local show_file="$4"

  AGENTIC_OLLAMA_ESTIMATOR_TAGS_FILE="${tags_file}" \
    AGENTIC_OLLAMA_ESTIMATOR_SHOW_FILE="${show_file}" \
    ollama_context_estimate_report "${model}" "${requested_context}" "${mem_limit}"
}

qwen_report="$(run_report "qwen3-coder:30b" "262144" "64g" "${qwen_show_file}")" \
  || fail "qwen estimator report failed"
echo "${qwen_report}" | grep -q '^model_max_context=262144$' \
  || fail "qwen estimator must report model max context 262144"
echo "${qwen_report}" | grep -q '^kv_bytes_per_token=98304$' \
  || fail "qwen estimator must report kv_bytes_per_token=98304"
echo "${qwen_report}" | grep -q '^estimated_max_fitting_context=262144$' \
  || fail "qwen estimator must keep full 262144 context under 64g"
ok "qwen estimator keeps full default context under 64g"

nemotron_report="$(run_report "nemotron-cascade-2:30b" "262144" "110g" "${nemotron_show_file}")" \
  || fail "nemotron estimator report failed"
echo "${nemotron_report}" | grep -q '^kv_bytes_per_token=851968$' \
  || fail "nemotron estimator must report kv_bytes_per_token=851968"
echo "${nemotron_report}" | grep -q '^estimated_max_fitting_context=108883$' \
  || fail "nemotron estimator must report max fitting context 108883 under 110g"
ok "nemotron estimator computes reduced max fitting context under 110g"

ok "00_ollama_context_estimator passed"
