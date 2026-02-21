#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/../../scripts/lib/runtime.sh"

usage() {
  cat <<USAGE
Usage:
  rollback.sh <release_id>
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

main() {
  local release_id="${1:-}"
  if [[ "${release_id}" == "-h" || "${release_id}" == "--help" || "${release_id}" == "help" ]]; then
    usage
    exit 0
  fi
  [[ -n "${release_id}" ]] || {
    usage
    die "missing release_id"
  }

  require_cmd docker
  require_cmd python3

  local release_dir="${AGENTIC_ROOT}/deployments/releases/${release_id}"
  [[ -d "${release_dir}" ]] || die "release not found: ${release_dir}"
  [[ -f "${release_dir}/images.json" ]] || die "missing release images manifest: ${release_dir}/images.json"
  [[ -f "${release_dir}/compose.files" ]] || die "missing compose file list: ${release_dir}/compose.files"

  local -a compose_files=()
  mapfile -t compose_files < <(grep -Ev '^\s*$' "${release_dir}/compose.files")
  [[ "${#compose_files[@]}" -gt 0 ]] || die "release ${release_id} contains no compose files"

  local compose_file
  local -a compose_args=()
  for compose_file in "${compose_files[@]}"; do
    [[ -f "${compose_file}" ]] || die "compose file from release is missing: ${compose_file}"
    compose_args+=("-f" "${compose_file}")
  done

  local override_file services_file
  override_file="$(mktemp)"
  services_file="$(mktemp)"
  trap 'if [[ -n "${override_file:-}" ]]; then rm -f "${override_file}"; fi; if [[ -n "${services_file:-}" ]]; then rm -f "${services_file}"; fi' EXIT

  python3 - "${release_dir}/images.json" "${override_file}" "${services_file}" <<'PY'
import json
import sys

images_path = sys.argv[1]
override_path = sys.argv[2]
services_path = sys.argv[3]

with open(images_path, "r", encoding="utf-8") as fh:
    images = json.load(fh)

services = {}
for item in images:
    service = item.get("service")
    if not service:
        continue
    pinned = item.get("repo_digest") or item.get("resolved_image") or item.get("configured_image")
    if pinned:
        services[service] = pinned

with open(override_path, "w", encoding="utf-8") as fh:
    fh.write("services:\n")
    for service in sorted(services):
        fh.write(f"  {service}:\n")
        fh.write(f"    image: {services[service]}\n")

with open(services_path, "w", encoding="utf-8") as fh:
    for service in sorted(services):
        fh.write(f"{service}\n")
PY

  local -a target_services=()
  mapfile -t target_services < <(grep -Ev '^\s*$' "${services_file}")
  [[ "${#target_services[@]}" -gt 0 ]] || die "release ${release_id} contains no rollback targets"

  docker compose \
    --project-name "${AGENTIC_COMPOSE_PROJECT}" \
    "${compose_args[@]}" \
    -f "${override_file}" \
    up -d --remove-orphans --no-build \
    "${target_services[@]}"

  local changes_log="${AGENTIC_ROOT}/deployments/changes.log"
  install -d -m 0750 "$(dirname "${changes_log}")"
  touch "${changes_log}"
  chmod 0640 "${changes_log}"
  printf '%s action=rollback release=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${release_id}" >>"${changes_log}"

  ln -sfn "${release_dir}" "${AGENTIC_ROOT}/deployments/current"
  printf 'rollback completed to release=%s\n' "${release_id}"
}

main "$@"
