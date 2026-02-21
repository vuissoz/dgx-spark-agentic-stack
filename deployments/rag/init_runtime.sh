#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
EXAMPLE_CORPUS_DIR="${REPO_ROOT}/examples/rag/corpus"
DEPLOYMENT_SCRIPT_DIR="${REPO_ROOT}/deployments/rag"
RAG_SCHEMA_TEMPLATE="${DEPLOYMENT_SCRIPT_DIR}/document.schema.json"

log() {
  echo "INFO: $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

repair_rootless_qdrant_layout() {
  local qdrant_dir="${AGENTIC_ROOT}/rag/qdrant"
  local snapshots_dir="${AGENTIC_ROOT}/rag/qdrant-snapshots"
  local needs_repair=0
  local entry=""
  local target_uid="${AGENT_RUNTIME_UID:-$(id -u)}"
  local target_gid="${AGENT_RUNTIME_GID:-$(id -g)}"

  [[ "${EUID}" -ne 0 ]] || return 0
  [[ -d "${qdrant_dir}" ]] || return 0

  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    if [[ ! -w "${entry}" ]]; then
      needs_repair=1
      break
    fi
  done < <(find "${qdrant_dir}" -mindepth 1 -maxdepth 1 -print | sort)

  if [[ "${needs_repair}" -eq 1 ]]; then
    command -v docker >/dev/null 2>&1 \
      || die "docker command is required to repair legacy qdrant ownership in rootless-dev"
    docker run --rm \
      -v "${qdrant_dir}:/repair/qdrant" \
      -v "${snapshots_dir}:/repair/snapshots" \
      busybox:1.36.1 sh -lc \
      "chown -R ${target_uid}:${target_gid} /repair/qdrant /repair/snapshots && chmod -R u+rwX,g+rwX,o-rwx /repair/qdrant /repair/snapshots" \
      || die "failed to repair qdrant ownership for rootless-dev runtime"
    log "repaired legacy qdrant ownership with containerized chown (uid=${target_uid} gid=${target_gid})"
  fi

  install -d -m 0770 "${qdrant_dir}/aliases"
  install -d -m 0770 "${qdrant_dir}/collections"
  chmod 0770 "${qdrant_dir}" "${snapshots_dir}" || true
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
  install -d -m 0750 "${AGENTIC_ROOT}/rag/config"
  install -d -m 0770 "${AGENTIC_ROOT}/rag/qdrant"
  install -d -m 0770 "${AGENTIC_ROOT}/rag/qdrant-snapshots"
  install -d -m 0770 "${AGENTIC_ROOT}/rag/docs"
  install -d -m 0750 "${AGENTIC_ROOT}/rag/scripts"
  install -d -m 0770 "${AGENTIC_ROOT}/rag/retriever"
  install -d -m 0770 "${AGENTIC_ROOT}/rag/retriever/state"
  install -d -m 0770 "${AGENTIC_ROOT}/rag/retriever/logs"
  install -d -m 0770 "${AGENTIC_ROOT}/rag/worker"
  install -d -m 0770 "${AGENTIC_ROOT}/rag/worker/state"
  install -d -m 0770 "${AGENTIC_ROOT}/rag/worker/logs"
  install -d -m 0770 "${AGENTIC_ROOT}/rag/opensearch"

  if [[ -d "${EXAMPLE_CORPUS_DIR}" ]]; then
    while IFS= read -r source_file; do
      filename="$(basename "${source_file}")"
      copy_if_missing "${source_file}" "${AGENTIC_ROOT}/rag/docs/${filename}" 0640
    done < <(find "${EXAMPLE_CORPUS_DIR}" -maxdepth 1 -type f -name '*.txt' | sort)
  fi

  copy_if_missing "${DEPLOYMENT_SCRIPT_DIR}/ingest.sh" "${AGENTIC_ROOT}/rag/scripts/ingest.sh" 0750
  copy_if_missing "${DEPLOYMENT_SCRIPT_DIR}/query_smoke.sh" "${AGENTIC_ROOT}/rag/scripts/query_smoke.sh" 0750
  copy_if_missing "${RAG_SCHEMA_TEMPLATE}" "${AGENTIC_ROOT}/rag/config/document.schema.json" 0640

  if [[ "${EUID}" -ne 0 ]]; then
    repair_rootless_qdrant_layout
    chmod 0770 "${AGENTIC_ROOT}/rag/qdrant" \
      "${AGENTIC_ROOT}/rag/qdrant-snapshots" \
      "${AGENTIC_ROOT}/rag/docs" \
      "${AGENTIC_ROOT}/rag/retriever/state" \
      "${AGENTIC_ROOT}/rag/retriever/logs" \
      "${AGENTIC_ROOT}/rag/worker/state" \
      "${AGENTIC_ROOT}/rag/worker/logs" \
      "${AGENTIC_ROOT}/rag/opensearch"
    log "non-root runtime init: relaxed rag dirs permissions for userns compatibility"
  fi
}

main "$@"
