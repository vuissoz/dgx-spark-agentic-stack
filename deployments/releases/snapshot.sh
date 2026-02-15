#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/../../scripts/lib/runtime.sh"

reason="manual"
declare -a compose_files=()

usage() {
  cat <<USAGE
Usage:
  snapshot.sh [--reason <reason>] [compose_file...]
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

existing_compose_files() {
  local -a ordered_targets=(core agents ui obs rag optional)
  local target compose_file
  for target in "${ordered_targets[@]}"; do
    case "${target}" in
      core) compose_file="${AGENTIC_COMPOSE_DIR}/compose.core.yml" ;;
      agents) compose_file="${AGENTIC_COMPOSE_DIR}/compose.agents.yml" ;;
      ui) compose_file="${AGENTIC_COMPOSE_DIR}/compose.ui.yml" ;;
      obs) compose_file="${AGENTIC_COMPOSE_DIR}/compose.obs.yml" ;;
      rag) compose_file="${AGENTIC_COMPOSE_DIR}/compose.rag.yml" ;;
      optional) compose_file="${AGENTIC_COMPOSE_DIR}/compose.optional.yml" ;;
      *) continue ;;
    esac
    [[ -f "${compose_file}" ]] && printf '%s\n' "${compose_file}"
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason)
        [[ $# -ge 2 ]] || die "--reason requires a value"
        reason="$2"
        shift 2
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        compose_files+=("$1")
        shift
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_cmd docker
  require_cmd python3

  if [[ "${#compose_files[@]}" -eq 0 ]]; then
    mapfile -t compose_files < <(existing_compose_files)
  fi
  [[ "${#compose_files[@]}" -gt 0 ]] || die "no compose files found for snapshot"

  local compose_file
  local -a compose_args=()
  for compose_file in "${compose_files[@]}"; do
    [[ -f "${compose_file}" ]] || die "compose file not found: ${compose_file}"
    compose_args+=("-f" "${compose_file}")
  done

  local release_id release_dir current_link changes_log
  release_id="$(date -u +%Y%m%dT%H%M%SZ)"
  release_dir="${AGENTIC_ROOT}/deployments/releases/${release_id}"
  current_link="${AGENTIC_ROOT}/deployments/current"
  changes_log="${AGENTIC_ROOT}/deployments/changes.log"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments/releases"
  install -d -m 0750 "${release_dir}"

  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" "${compose_args[@]}" config >"${release_dir}/compose.effective.yml"
  printf '%s\n' "${compose_files[@]}" >"${release_dir}/compose.files"

  local runtime_env="${AGENTIC_ROOT}/deployments/runtime.env"
  if [[ -f "${runtime_env}" ]]; then
    grep -Evi '(secret|token|password|api_key|private_key)' "${runtime_env}" >"${release_dir}/runtime.env" || true
  else
    : >"${release_dir}/runtime.env"
  fi

  local -a container_ids=()
  mapfile -t container_ids < <(
    docker ps --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" --format '{{.ID}}'
  )
  [[ "${#container_ids[@]}" -gt 0 ]] || die "no running containers found for compose project '${AGENTIC_COMPOSE_PROJECT}'"

  local raw_rows_file="${release_dir}/images.raw"
  : >"${raw_rows_file}"

  local cid row service configured_image resolved_image state health repo_digest
  for cid in "${container_ids[@]}"; do
    row="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}|{{.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}")"
    IFS='|' read -r service configured_image resolved_image state health <<<"${row}"
    repo_digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "${configured_image}" 2>/dev/null || true)"
    if [[ "${repo_digest}" == "<no value>" ]]; then
      repo_digest=""
    fi
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
      "${service}" "${configured_image}" "${resolved_image}" "${repo_digest}" "${state}" "${health}" "${cid}" >>"${raw_rows_file}"
  done

  python3 - "${raw_rows_file}" "${release_dir}/images.json" "${release_dir}/health_report.json" <<'PY'
import json
import sys

raw_path = sys.argv[1]
images_path = sys.argv[2]
health_path = sys.argv[3]

rows = []
with open(raw_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) != 7:
            continue
        service, configured_image, resolved_image, repo_digest, state, health, container_id = parts
        rows.append(
            {
                "service": service,
                "configured_image": configured_image,
                "resolved_image": resolved_image,
                "repo_digest": repo_digest,
                "state": state,
                "health": health,
                "container_id": container_id,
            }
        )

rows.sort(key=lambda item: item["service"])
with open(images_path, "w", encoding="utf-8") as fh:
    json.dump(rows, fh, indent=2, sort_keys=True)

health_report = {
    "healthy": all(item["state"] == "running" and item["health"] in ("healthy", "none") for item in rows),
    "services": [
        {
            "service": item["service"],
            "state": item["state"],
            "health": item["health"],
        }
        for item in rows
    ],
}
with open(health_path, "w", encoding="utf-8") as fh:
    json.dump(health_report, fh, indent=2, sort_keys=True)
PY

  rm -f "${raw_rows_file}"

  {
    printf 'release_id=%s\n' "${release_id}"
    printf 'reason=%s\n' "${reason}"
    printf 'created_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'git_commit=%s\n' "$(git -C "${AGENTIC_REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf 'docker_version=%s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
    printf 'docker_compose_version=%s\n' "$(docker compose version --short 2>/dev/null || echo unknown)"
  } >"${release_dir}/release.meta"

  install -d -m 0750 "$(dirname "${changes_log}")"
  touch "${changes_log}"
  chmod 0640 "${changes_log}"
  printf '%s action=snapshot release=%s reason=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${release_id}" "${reason}" >>"${changes_log}"

  ln -sfn "${release_dir}" "${current_link}"
  printf '%s\n' "${release_id}"
}

main "$@"
