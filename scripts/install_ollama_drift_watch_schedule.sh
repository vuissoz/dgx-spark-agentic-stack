#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

usage() {
  cat <<'USAGE'
Usage:
  agent ollama-drift schedule [--disable] [--dry-run] [--on-calendar <expr>] [--cron <expr>] [--force-cron]

Description:
  Install or remove a weekly scheduled ollama contract drift watch.
  Preferred backend: systemd user timer. Fallback: user crontab.
USAGE
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

MODE="install"
DRY_RUN=0
FORCE_CRON=0
ON_CALENDAR="${AGENTIC_OLLAMA_DRIFT_ON_CALENDAR:-Mon *-*-* 07:17:00}"
CRON_EXPR="${AGENTIC_OLLAMA_DRIFT_CRON:-17 7 * * 1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disable)
      MODE="disable"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --on-calendar)
      [[ $# -ge 2 ]] || die "missing value for --on-calendar"
      ON_CALENDAR="$2"
      shift 2
      ;;
    --cron)
      [[ $# -ge 2 ]] || die "missing value for --cron"
      CRON_EXPR="$2"
      shift 2
      ;;
    --force-cron)
      FORCE_CRON=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

marker_begin="# BEGIN AGENTIC_OLLAMA_DRIFT_WATCH"
marker_end="# END AGENTIC_OLLAMA_DRIFT_WATCH"
cron_cmd="AGENTIC_PROFILE=${AGENTIC_PROFILE} ${AGENTIC_REPO_ROOT}/agent ollama-drift watch >> ${AGENTIC_ROOT}/deployments/ollama-drift/logs/cron.log 2>&1"
cron_entry="${CRON_EXPR} ${cron_cmd}"

systemd_user_available() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user show-environment >/dev/null 2>&1
}

remove_cron_block() {
  local current=""
  local tmp
  tmp="$(mktemp)"

  current="$(crontab -l 2>/dev/null || true)"
  awk -v begin="${marker_begin}" -v end="${marker_end}" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' <<<"${current}" >"${tmp}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "ollama-drift schedule dry-run: would install crontab without drift block"
    rm -f "${tmp}"
    return 0
  fi

  crontab "${tmp}"
  rm -f "${tmp}"
}

install_cron_block() {
  local current=""
  local tmp
  tmp="$(mktemp)"

  current="$(crontab -l 2>/dev/null || true)"
  awk -v begin="${marker_begin}" -v end="${marker_end}" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' <<<"${current}" >"${tmp}"

  {
    printf '%s\n' "${marker_begin}"
    printf '%s\n' "${cron_entry}"
    printf '%s\n' "${marker_end}"
  } >>"${tmp}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "ollama-drift schedule dry-run: would install crontab entry"
    log "  ${cron_entry}"
    rm -f "${tmp}"
    return 0
  fi

  crontab "${tmp}"
  rm -f "${tmp}"
}

service_name="agentic-ollama-drift-watch.service"
timer_name="agentic-ollama-drift-watch.timer"
user_unit_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
wrapper_script="${AGENTIC_ROOT}/deployments/ollama-drift/run-weekly.sh"

install -d -m 0750 "${AGENTIC_ROOT}/deployments/ollama-drift"
install -d -m 0750 "${AGENTIC_ROOT}/deployments/ollama-drift/logs"

if [[ "${MODE}" == "disable" ]]; then
  if systemd_user_available; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      log "ollama-drift schedule dry-run: would disable systemd user timer ${timer_name}"
    else
      systemctl --user disable --now "${timer_name}" >/dev/null 2>&1 || true
      systemctl --user disable --now "${service_name}" >/dev/null 2>&1 || true
      rm -f "${user_unit_dir}/${service_name}" "${user_unit_dir}/${timer_name}"
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      log "ollama-drift schedule: disabled systemd user timer"
    fi
  fi

  remove_cron_block
  log "ollama-drift schedule: cron block removed (if present)"
  exit 0
fi

cat >"${wrapper_script}" <<EOF_WRAPPER
#!/usr/bin/env bash
set -euo pipefail
export AGENTIC_PROFILE='${AGENTIC_PROFILE}'
cd '${AGENTIC_REPO_ROOT}'
exec '${AGENTIC_REPO_ROOT}/agent' ollama-drift watch
EOF_WRAPPER
chmod 0750 "${wrapper_script}"

if [[ "${FORCE_CRON}" != "1" ]] && systemd_user_available; then
  install -d -m 0750 "${user_unit_dir}"

  cat >"${user_unit_dir}/${service_name}" <<EOF_SERVICE
[Unit]
Description=Agentic Ollama contract drift watch
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${wrapper_script}
WorkingDirectory=${AGENTIC_REPO_ROOT}

[Install]
WantedBy=default.target
EOF_SERVICE

  cat >"${user_unit_dir}/${timer_name}" <<EOF_TIMER
[Unit]
Description=Weekly Agentic Ollama contract drift watch

[Timer]
OnCalendar=${ON_CALENDAR}
Persistent=true
Unit=${service_name}

[Install]
WantedBy=timers.target
EOF_TIMER

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "ollama-drift schedule dry-run: would install systemd user timer"
    log "  unit=${user_unit_dir}/${service_name}"
    log "  timer=${user_unit_dir}/${timer_name}"
    log "  OnCalendar=${ON_CALENDAR}"
  else
    systemctl --user daemon-reload
    systemctl --user enable --now "${timer_name}"
    log "ollama-drift schedule: installed systemd user timer ${timer_name}"
    systemctl --user list-timers "${timer_name}" --no-pager || true
  fi

  remove_cron_block
  exit 0
fi

warn "systemd --user unavailable or --force-cron set, using crontab fallback"
install_cron_block
log "ollama-drift schedule: cron entry installed (${CRON_EXPR})"
