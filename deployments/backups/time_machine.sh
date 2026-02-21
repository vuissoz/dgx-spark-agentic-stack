#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/../../scripts/lib/runtime.sh"

BACKUP_ROOT="${AGENTIC_ROOT}/deployments/backups"
SNAPSHOTS_DIR="${BACKUP_ROOT}/snapshots"
LATEST_LINK="${BACKUP_ROOT}/latest"
CHANGES_LOG="${AGENTIC_ROOT}/deployments/changes.log"

KEEP_HOURLY="${AGENTIC_BACKUP_KEEP_HOURLY:-24}"
KEEP_DAILY="${AGENTIC_BACKUP_KEEP_DAILY:-14}"
KEEP_WEEKLY="${AGENTIC_BACKUP_KEEP_WEEKLY:-8}"

usage() {
  cat <<USAGE
Usage:
  time_machine.sh run
  time_machine.sh list
  time_machine.sh restore <snapshot_id> [--yes]

Environment:
  AGENTIC_BACKUP_KEEP_HOURLY   snapshots kept at hourly granularity (default: 24)
  AGENTIC_BACKUP_KEEP_DAILY    snapshots kept at daily granularity (default: 14)
  AGENTIC_BACKUP_KEEP_WEEKLY   snapshots kept at weekly granularity (default: 8)
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_non_negative_int() {
  local value="$1"
  local label="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${label} must be a non-negative integer (got '${value}')"
}

sanitize_runtime_env() {
  local output_file="$1"
  local runtime_env="${AGENTIC_ROOT}/deployments/runtime.env"

  if [[ -f "${runtime_env}" ]]; then
    grep -Evi '(secret|token|password|api_key|private_key)' "${runtime_env}" >"${output_file}" || true
  else
    : >"${output_file}"
  fi
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

capture_system_metadata() {
  local snapshot_dir="$1"
  local metadata_dir="${snapshot_dir}/metadata"
  local compose_snapshot_dir="${metadata_dir}/compose"
  local config_dir="${metadata_dir}/config"
  local compose_effective_file="${config_dir}/compose.effective.yml"
  local compose_file_list="${config_dir}/compose.files"

  mkdir -p "${compose_snapshot_dir}" "${config_dir}"

  local -a compose_files=()
  local -a compose_args=()
  local compose_file
  mapfile -t compose_files < <(existing_compose_files)

  if [[ "${#compose_files[@]}" -gt 0 ]]; then
    for compose_file in "${compose_files[@]}"; do
      compose_args+=("-f" "${compose_file}")
      cp "${compose_file}" "${compose_snapshot_dir}/$(basename "${compose_file}")"
    done
    printf '%s\n' "${compose_files[@]}" >"${compose_file_list}"
  else
    : >"${compose_file_list}"
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && [[ "${#compose_args[@]}" -gt 0 ]]; then
    if ! docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" "${compose_args[@]}" config >"${compose_effective_file}" 2>"${config_dir}/compose.config.stderr"; then
      warn "unable to export compose effective config for backup metadata"
      rm -f "${compose_effective_file}"
    fi
  fi

  sanitize_runtime_env "${config_dir}/runtime.env"

  if [[ "${AGENTIC_PROFILE}" == "strict-prod" ]] && command -v iptables-save >/dev/null 2>&1; then
    if ! iptables-save >"${config_dir}/iptables-save.rules" 2>/dev/null; then
      warn "unable to capture iptables-save snapshot"
    fi
  fi
}

last_snapshot_id() {
  local latest_target
  if [[ -L "${LATEST_LINK}" ]]; then
    latest_target="$(readlink -f "${LATEST_LINK}" 2>/dev/null || true)"
    if [[ -n "${latest_target}" && -d "${latest_target}" ]]; then
      basename "${latest_target}"
      return 0
    fi
  fi

  if [[ -d "${SNAPSHOTS_DIR}" ]]; then
    find "${SNAPSHOTS_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1
  fi
}

write_backup_metadata_json() {
  local snapshot_id="$1"
  local snapshot_dir="$2"
  local previous_snapshot_id="$3"
  local changed_entries="$4"
  local metadata_file="${snapshot_dir}/metadata/backup.json"
  local created_at actor size_bytes

  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  actor="${SUDO_USER:-${USER:-unknown}}"
  size_bytes="$(du -sb "${snapshot_dir}" 2>/dev/null | awk '{print $1}')"
  size_bytes="${size_bytes:-0}"

  python3 - "${metadata_file}" "${snapshot_id}" "${created_at}" "${actor}" "${AGENTIC_PROFILE}" \
    "${AGENTIC_ROOT}" "${previous_snapshot_id}" "${KEEP_HOURLY}" "${KEEP_DAILY}" "${KEEP_WEEKLY}" \
    "${changed_entries}" "${size_bytes}" <<'PY'
import json
import sys

metadata_path = sys.argv[1]
snapshot_id = sys.argv[2]
created_at = sys.argv[3]
actor = sys.argv[4]
profile = sys.argv[5]
source_root = sys.argv[6]
previous_snapshot_id = sys.argv[7]
keep_hourly = int(sys.argv[8])
keep_daily = int(sys.argv[9])
keep_weekly = int(sys.argv[10])
changed_entries = int(sys.argv[11])
size_bytes = int(sys.argv[12])

payload = {
    "snapshot_id": snapshot_id,
    "created_at": created_at,
    "actor": actor,
    "profile": profile,
    "source_root": source_root,
    "previous_snapshot_id": previous_snapshot_id or None,
    "changed_entries": changed_entries,
    "size_bytes": size_bytes,
    "retention": {
        "hourly": keep_hourly,
        "daily": keep_daily,
        "weekly": keep_weekly,
    },
}

with open(metadata_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
PY
}

prune_snapshots() {
  local keep_hourly="$1"
  local keep_daily="$2"
  local keep_weekly="$3"

  python3 - "${SNAPSHOTS_DIR}" "${keep_hourly}" "${keep_daily}" "${keep_weekly}" <<'PY'
import os
import shutil
import sys
from datetime import datetime, timedelta, timezone

snapshots_dir = sys.argv[1]
keep_hourly = int(sys.argv[2])
keep_daily = int(sys.argv[3])
keep_weekly = int(sys.argv[4])

if not os.path.isdir(snapshots_dir):
    raise SystemExit(0)

snapshots = []
for name in os.listdir(snapshots_dir):
    path = os.path.join(snapshots_dir, name)
    if not os.path.isdir(path):
        continue
    try:
        dt = datetime.strptime(name, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        continue
    snapshots.append((dt, name, path))

if not snapshots:
    raise SystemExit(0)

snapshots.sort(reverse=True)
keep = set()
latest_dt = snapshots[0][0]
keep.add(snapshots[0][1])

hourly_cutoff = latest_dt
if keep_hourly > 0:
    hourly_cutoff = latest_dt - timedelta(hours=keep_hourly)
    for dt, name, _ in snapshots:
        if dt >= hourly_cutoff:
            keep.add(name)

daily_cutoff = hourly_cutoff
if keep_daily > 0:
    daily_cutoff = latest_dt - timedelta(days=keep_daily)
    daily = set()
    for dt, name, _ in snapshots:
        if dt >= hourly_cutoff:
            continue
        if dt < daily_cutoff:
            continue
        key = dt.strftime("%Y%m%d")
        if key in daily:
            continue
        daily.add(key)
        keep.add(name)

if keep_weekly > 0:
    weekly_cutoff = latest_dt - timedelta(weeks=keep_weekly)
    weekly = set()
    for dt, name, _ in snapshots:
        if dt >= daily_cutoff:
            continue
        if dt < weekly_cutoff:
            continue
        iso_year, iso_week, _ = dt.isocalendar()
        key = f"{iso_year:04d}-W{iso_week:02d}"
        if key in weekly:
            continue
        weekly.add(key)
        keep.add(name)

removed = []
for _, name, path in snapshots:
    if name in keep:
        continue
    shutil.rmtree(path)
    removed.append(name)

for name in removed:
    print(name)
PY
}

write_changes_log() {
  local action="$1"
  local snapshot_id="$2"
  local result="$3"
  local extra="$4"

  install -d -m 0750 "$(dirname "${CHANGES_LOG}")"
  touch "${CHANGES_LOG}"
  chmod 0640 "${CHANGES_LOG}" || true

  printf '%s action=%s snapshot_id=%s result=%s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${action}" "${snapshot_id}" "${result}" "${extra}" \
    >>"${CHANGES_LOG}"
}

backup_run() {
  require_cmd rsync
  require_cmd python3

  [[ -d "${AGENTIC_ROOT}" ]] || die "runtime root does not exist: ${AGENTIC_ROOT}"

  install -d -m 0750 "${SNAPSHOTS_DIR}"

  local snapshot_id snapshot_dir data_dir metadata_dir exclude_file
  local previous_snapshot_id previous_data_dir
  local changed_entries

  snapshot_id="$(date -u +%Y%m%dT%H%M%SZ)"
  snapshot_dir="${SNAPSHOTS_DIR}/${snapshot_id}"

  if [[ -e "${snapshot_dir}" ]]; then
    sleep 1
    snapshot_id="$(date -u +%Y%m%dT%H%M%SZ)"
    snapshot_dir="${SNAPSHOTS_DIR}/${snapshot_id}"
  fi

  data_dir="${snapshot_dir}/data"
  metadata_dir="${snapshot_dir}/metadata"
  mkdir -p "${data_dir}" "${metadata_dir}"

  previous_snapshot_id="$(last_snapshot_id || true)"
  previous_data_dir=""
  if [[ -n "${previous_snapshot_id}" && -d "${SNAPSHOTS_DIR}/${previous_snapshot_id}/data" ]]; then
    previous_data_dir="${SNAPSHOTS_DIR}/${previous_snapshot_id}/data"
  fi

  exclude_file="$(mktemp)"
  cat >"${exclude_file}" <<'EXCLUDES'
/secrets/
/secrets/**
/deployments/backups/
/deployments/backups/**
/deployments/cleanup-exports/
/deployments/cleanup-exports/**
**/*.pem
**/*.key
**/*.p12
**/*.pfx
**/id_rsa
**/id_ed25519
EXCLUDES

  local -a rsync_args=(
    -a
    --delete
    --numeric-ids
    --exclude-from "${exclude_file}"
    --itemize-changes
    "--out-format=%i|%n%L"
  )

  if [[ -n "${previous_data_dir}" ]]; then
    rsync_args+=(--link-dest "${previous_data_dir}")
  fi

  rsync "${rsync_args[@]}" "${AGENTIC_ROOT}/" "${data_dir}/" >"${metadata_dir}/rsync.changes"
  rm -f "${exclude_file}"

  find "${data_dir}" -mindepth 1 -printf '%P\n' | sort >"${metadata_dir}/files.list"

  if grep -Eq '^secrets(/|$)' "${metadata_dir}/files.list"; then
    write_changes_log "backup-run" "${snapshot_id}" "failed" "reason=secret_path_included"
    die "backup snapshot unexpectedly contains secrets/ path"
  fi

  if grep -Eqi '(^|/)(id_rsa|id_ed25519|.+\.(pem|key|p12|pfx))$' "${metadata_dir}/files.list"; then
    write_changes_log "backup-run" "${snapshot_id}" "failed" "reason=sensitive_key_material_detected"
    die "backup snapshot unexpectedly contains key/certificate material"
  fi

  changed_entries="$(awk 'NF{count+=1} END{print count+0}' "${metadata_dir}/rsync.changes")"
  capture_system_metadata "${snapshot_dir}"
  write_backup_metadata_json "${snapshot_id}" "${snapshot_dir}" "${previous_snapshot_id}" "${changed_entries}"

  ln -sfn "${snapshot_dir}" "${LATEST_LINK}"

  local removed_snapshot_ids=""
  if [[ -d "${SNAPSHOTS_DIR}" ]]; then
    removed_snapshot_ids="$(prune_snapshots "${KEEP_HOURLY}" "${KEEP_DAILY}" "${KEEP_WEEKLY}" || true)"
  fi

  local removed_count=0
  if [[ -n "${removed_snapshot_ids}" ]]; then
    removed_count="$(printf '%s\n' "${removed_snapshot_ids}" | awk 'NF{count+=1} END{print count+0}')"
  fi

  write_changes_log "backup-run" "${snapshot_id}" "ok" "changed_entries=${changed_entries} removed=${removed_count}"

  printf 'snapshot_id=%s\n' "${snapshot_id}"
  printf 'snapshot_dir=%s\n' "${snapshot_dir}"
  printf 'changed_entries=%s\n' "${changed_entries}"
  printf 'retention=hourly:%s,daily:%s,weekly:%s\n' "${KEEP_HOURLY}" "${KEEP_DAILY}" "${KEEP_WEEKLY}"
}

backup_list() {
  require_cmd python3

  install -d -m 0750 "${SNAPSHOTS_DIR}"

  printf 'retention=hourly:%s,daily:%s,weekly:%s\n' "${KEEP_HOURLY}" "${KEEP_DAILY}" "${KEEP_WEEKLY}"

  python3 - "${SNAPSHOTS_DIR}" <<'PY'
import json
import os
import sys

snapshots_dir = sys.argv[1]
rows = []

for name in sorted(os.listdir(snapshots_dir), reverse=True):
    path = os.path.join(snapshots_dir, name)
    if not os.path.isdir(path):
        continue

    metadata_file = os.path.join(path, "metadata", "backup.json")
    created_at = "unknown"
    changed_entries = 0
    size_bytes = 0

    if os.path.isfile(metadata_file):
        try:
            with open(metadata_file, "r", encoding="utf-8") as fh:
                metadata = json.load(fh)
            created_at = str(metadata.get("created_at") or "unknown")
            changed_entries = int(metadata.get("changed_entries") or 0)
            size_bytes = int(metadata.get("size_bytes") or 0)
        except Exception:
            pass

    if size_bytes <= 0:
        total = 0
        for root, _, files in os.walk(path):
            for filename in files:
                file_path = os.path.join(root, filename)
                try:
                    total += os.lstat(file_path).st_size
                except OSError:
                    continue
        size_bytes = total

    rows.append((name, created_at, size_bytes, changed_entries))

if not rows:
    print("snapshot_count=0")
else:
    print(f"snapshot_count={len(rows)}")
    for snapshot_id, created_at, size_bytes, changed_entries in rows:
        print(
            "snapshot_id={sid} created_at={created} size_bytes={size} changed_entries={changed}".format(
                sid=snapshot_id,
                created=created_at,
                size=size_bytes,
                changed=changed_entries,
            )
        )
PY
}

backup_restore() {
  local snapshot_id="${1:-}"
  shift || true
  local force="0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes)
        force="1"
        shift
        ;;
      *)
        die "Usage: time_machine.sh restore <snapshot_id> [--yes]"
        ;;
    esac
  done

  [[ -n "${snapshot_id}" ]] || die "Usage: time_machine.sh restore <snapshot_id> [--yes]"

  local snapshot_dir="${SNAPSHOTS_DIR}/${snapshot_id}"
  local data_dir="${snapshot_dir}/data"
  [[ -d "${data_dir}" ]] || die "backup snapshot not found: ${snapshot_dir}"

  if [[ "${force}" != "1" ]]; then
    printf 'Restore will replace runtime data under %s (excluding secrets/backups). Type RESTORE to continue: ' "${AGENTIC_ROOT}"
    local confirmation
    IFS= read -r confirmation || die "restore aborted: confirmation not provided"
    [[ "${confirmation}" == "RESTORE" ]] || die "restore aborted: confirmation token mismatch"
  fi

  install -d -m 0750 "${AGENTIC_ROOT}"

  rsync -a --delete --numeric-ids \
    --exclude '/secrets/***' \
    --exclude '/deployments/backups/***' \
    "${data_dir}/" "${AGENTIC_ROOT}/"

  write_changes_log "backup-restore" "${snapshot_id}" "ok" ""
  printf 'restore completed snapshot_id=%s\n' "${snapshot_id}"
}

main() {
  require_non_negative_int "${KEEP_HOURLY}" "AGENTIC_BACKUP_KEEP_HOURLY"
  require_non_negative_int "${KEEP_DAILY}" "AGENTIC_BACKUP_KEEP_DAILY"
  require_non_negative_int "${KEEP_WEEKLY}" "AGENTIC_BACKUP_KEEP_WEEKLY"

  local action="${1:-}"
  shift || true

  case "${action}" in
    run)
      backup_run "$@"
      ;;
    list)
      backup_list "$@"
      ;;
    restore)
      backup_restore "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      die "unknown action '${action}'"
      ;;
  esac
}

main "$@"
