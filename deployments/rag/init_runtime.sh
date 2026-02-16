#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
EXAMPLE_CORPUS_DIR="${REPO_ROOT}/examples/rag/corpus"
DEPLOYMENT_SCRIPT_DIR="${REPO_ROOT}/deployments/rag"

log() {
  echo "INFO: $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

copy_if_missing() {
  local src="$1"
  local dst="$2"
  local mode="$3"

  [[ -f "${src}" ]] || die "template not found: ${src}"
  if [[ -f "${dst}" ]]; then
    log "preserve existing runtime file: ${dst}"
    return 0
  fi

  install -D -m "${mode}" "${src}" "${dst}"
  log "created runtime file: ${dst}"
}

main() {
  install -d -m 0750 "${AGENTIC_ROOT}/rag"
  install -d -m 0770 "${AGENTIC_ROOT}/rag/qdrant"
  install -d -m 0770 "${AGENTIC_ROOT}/rag/docs"
  install -d -m 0750 "${AGENTIC_ROOT}/rag/scripts"

  if [[ -d "${EXAMPLE_CORPUS_DIR}" ]]; then
    while IFS= read -r source_file; do
      filename="$(basename "${source_file}")"
      copy_if_missing "${source_file}" "${AGENTIC_ROOT}/rag/docs/${filename}" 0640
    done < <(find "${EXAMPLE_CORPUS_DIR}" -maxdepth 1 -type f -name '*.txt' | sort)
  fi

  copy_if_missing "${DEPLOYMENT_SCRIPT_DIR}/ingest.sh" "${AGENTIC_ROOT}/rag/scripts/ingest.sh" 0750
  copy_if_missing "${DEPLOYMENT_SCRIPT_DIR}/query_smoke.sh" "${AGENTIC_ROOT}/rag/scripts/query_smoke.sh" 0750

  if [[ "${EUID}" -ne 0 ]]; then
    chmod 0770 "${AGENTIC_ROOT}/rag/qdrant" "${AGENTIC_ROOT}/rag/docs"
    log "non-root runtime init: relaxed rag dirs permissions for userns compatibility"
  fi
}

main "$@"
