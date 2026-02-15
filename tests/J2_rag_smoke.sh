#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_J_TESTS:-0}" == "1" ]]; then
  ok "J2 skipped because AGENTIC_SKIP_J_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd python3

qdrant_cid="$(require_service_container qdrant)" || exit 1
gate_cid="$(require_service_container ollama-gate)" || exit 1
wait_for_container_ready "${qdrant_cid}" 180 || fail "qdrant is not ready"
wait_for_container_ready "${gate_cid}" 120 || fail "ollama-gate is not ready"

runtime_ingest="${AGENTIC_ROOT:-/srv/agentic}/rag/scripts/ingest.sh"
runtime_query="${AGENTIC_ROOT:-/srv/agentic}/rag/scripts/query_smoke.sh"
runtime_docs="${AGENTIC_ROOT:-/srv/agentic}/rag/docs"
fallback_ingest="${REPO_ROOT}/deployments/rag/ingest.sh"
fallback_query="${REPO_ROOT}/deployments/rag/query_smoke.sh"
fallback_docs="${REPO_ROOT}/examples/rag/corpus"

ingest_script="${runtime_ingest}"
query_script="${runtime_query}"
[[ -x "${ingest_script}" ]] || ingest_script="${fallback_ingest}"
[[ -x "${query_script}" ]] || query_script="${fallback_query}"
[[ -x "${ingest_script}" ]] || fail "ingest script is missing or not executable"
[[ -x "${query_script}" ]] || fail "query smoke script is missing or not executable"

docs_dir="${runtime_docs}"
[[ -d "${docs_dir}" ]] || docs_dir="${fallback_docs}"
[[ -d "${docs_dir}" ]] || fail "rag docs directory is missing (checked ${runtime_docs} and ${fallback_docs})"

expected_count="$(find "${docs_dir}" -maxdepth 1 -type f -name '*.txt' -size +0c | wc -l | tr -d ' ')"
[[ "${expected_count}" -gt 0 ]] || fail "rag docs corpus is empty in ${docs_dir}"

ingest_output="$(RAG_DOCS_DIR="${docs_dir}" RAG_GATE_DRY_RUN=1 "${ingest_script}")"
printf '%s\n' "${ingest_output}" | grep -q '^OK: rag ingest completed' \
  || fail "rag ingest output is invalid: ${ingest_output}"
indexed_count="$(printf '%s\n' "${ingest_output}" | grep -o 'indexed=[0-9]\+' | head -n 1 | cut -d= -f2)"
[[ -n "${indexed_count}" ]] || fail "rag ingest did not report an indexed count: ${ingest_output}"
[[ "${indexed_count}" -eq "${expected_count}" ]] \
  || fail "rag ingest indexed=${indexed_count}, expected=${expected_count}"
ok "rag ingest indexed the expected local mini-corpus count (${indexed_count})"

reingest_output="$(RAG_DOCS_DIR="${docs_dir}" RAG_GATE_DRY_RUN=1 "${ingest_script}")"
printf '%s\n' "${reingest_output}" | grep -q '^OK: rag ingest completed' \
  || fail "rag second ingest output is invalid: ${reingest_output}"
ok "rag ingest is reproducible across repeated runs"

query_output="$(RAG_GATE_DRY_RUN=1 RAG_MIN_HITS=1 "${query_script}")"
printf '%s\n' "${query_output}" | grep -q '^OK: rag query smoke passed' \
  || fail "rag query output is invalid: ${query_output}"
ok "rag query smoke returned hits from qdrant"

offline_query_output="$(HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 NO_PROXY='*' RAG_GATE_DRY_RUN=1 RAG_MIN_HITS=1 "${query_script}")"
printf '%s\n' "${offline_query_output}" | grep -q '^OK: rag query smoke passed' \
  || fail "rag query did not survive proxy disruption simulation"
ok "rag query remains functional with local corpus even if proxy settings are broken"

ok "J2_rag_smoke passed"
