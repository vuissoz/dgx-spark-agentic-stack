#!/usr/bin/env bash
set -euo pipefail

# Host-side, rootless-dev-only resource guard. It deliberately is not a
# container: Docker control and NVML access must remain outside containers.
PROJECT="${AGENTIC_COMPOSE_PROJECT:-agentic-dev}"
ROOT="${AGENTIC_ROOT:-${HOME}/.local/share/agentic}"
STATE_DIR="${ROOT}/runtime"
LOG_FILE="${ROOT}/logs/memory-watchdog.jsonl"
PID_FILE="${STATE_DIR}/memory-watchdog.pid"
QUARANTINE_FILE="${STATE_DIR}/memory-watchdog.quarantine"
INTERVAL="${AGENTIC_MEMORY_WATCHDOG_INTERVAL_SEC:-5}"
EMPTY_GRACE="${AGENTIC_MEMORY_WATCHDOG_EMPTY_GRACE_SEC:-30}"
DRY_RUN="${AGENTIC_MEMORY_WATCHDOG_DRY_RUN:-0}"

mkdir -p "${STATE_DIR}" "$(dirname "${LOG_FILE}")"

log_event() {
  local event="$1" detail="${2:-}"
  printf '{"ts":"%s","event":"%s","project":"%s","detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$PROJECT" "$detail" >>"${LOG_FILE}"
}

host_memory() {
  awk '/MemTotal:/ {total=$2} /MemAvailable:/ {avail=$2} END {if (total && avail) printf "%s %s\n", total, avail}' /proc/meminfo
}

gpu_memory() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv,noheader,nounits 2>/dev/null \
    | awk -F, '{gsub(/[[:space:]]/,"",$1); gsub(/[[:space:]]/,"",$2); gsub(/[[:space:]]/,"",$3); total+=$1; used+=$2; free+=$3} END {if (total) printf "%d %d %d\n", total, used, free}'
}

running_ids() {
  docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.ID}}'
}

percent() { awk -v a="$1" -v b="$2" 'BEGIN {if (b == 0) print 0; else printf "%d", (a*100)/b}'; }

human_mb() {
  awk -v value="$1" 'BEGIN {if (value ~ /GiB$/) {sub(/GiB$/, "", value); printf "%d", value*1024} else if (value ~ /MiB$/) {sub(/MiB$/, "", value); printf "%d", value} else if (value ~ /KiB$/) {sub(/KiB$/, "", value); printf "%d", value/1024} else {printf "%d", value/1024/1024}}'
}

container_memory_check() {
  local id usage limit current limit_mb ratio
  while IFS='|' read -r id usage; do
    [[ -n "$id" ]] || continue
    current="$(human_mb "${usage%% / *}")"
    limit="$(docker inspect --format '{{.HostConfig.Memory}}' "$id" 2>/dev/null || printf '0')"
    [[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]] || continue
    limit_mb=$((limit / 1024 / 1024))
    ratio="$(percent "$current" "$limit_mb")"
    if (( ratio >= ${AGENTIC_MEMORY_WATCHDOG_CONTAINER_STOP_PERCENT:-95} )); then
      stop_container "$id" "container-memory-${id}-${ratio}percent" || true
    elif (( ratio >= ${AGENTIC_MEMORY_WATCHDOG_CONTAINER_WARN_PERCENT:-80} )); then
      log_event "container-memory-warning" "container=${id},used_mb=${current},limit_mb=${limit_mb},percent=${ratio}"
    fi
  done < <(while IFS= read -r id; do docker stats --no-stream --format '{{.ID}}|{{.MemUsage}}' "$id" 2>/dev/null; done < <(running_ids))
}

choose_victim() {
  local line priority
  while IFS='|' read -r id name service priority; do
    [[ -n "$id" ]] || continue
    [[ "$priority" == "preemptible" ]] && { printf '%s|%s|%s\n' "$id" "$name" "$service"; return; }
  done < <(docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.service"}}|{{.Label "agentic.resource.priority"}}')
  while IFS='|' read -r id name service priority; do
    [[ -n "$id" && "$priority" != "critical" ]] && { printf '%s|%s|%s\n' "$id" "$name" "$service"; return; }
  done < <(docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.service"}}|{{.Label "agentic.resource.priority"}}')
}

stop_victim() {
  local reason="$1" victim id name service
  victim="$(choose_victim || true)"
  [[ -n "$victim" ]] || { log_event "no-preemptible-victim" "$reason"; return 1; }
  IFS='|' read -r id name service <<<"$victim"
  log_event "stop-requested" "service=${service},container=${name},reason=${reason},dry_run=${DRY_RUN}"
  [[ "$DRY_RUN" == "1" ]] && return 0
  docker update --restart=no "$id" >/dev/null 2>&1 || true
  docker stop --time "${AGENTIC_MEMORY_WATCHDOG_GRACE_SEC:-10}" "$id" >/dev/null 2>&1 || docker kill "$id" >/dev/null 2>&1 || true
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$reason" >>"${QUARANTINE_FILE}"
  log_event "quarantined" "service=${service},container=${name},reason=${reason}"
}

stop_container() {
  local id="$1" reason="$2" name service
  name="$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')"
  service="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$id" 2>/dev/null || true)"
  log_event "stop-requested" "service=${service},container=${name},reason=${reason},dry_run=${DRY_RUN}"
  [[ "$DRY_RUN" == "1" ]] && return 0
  docker update --restart=no "$id" >/dev/null 2>&1 || true
  docker stop --time "${AGENTIC_MEMORY_WATCHDOG_GRACE_SEC:-10}" "$id" >/dev/null 2>&1 || docker kill "$id" >/dev/null 2>&1 || true
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$reason" >>"${QUARANTINE_FILE}"
  log_event "quarantined" "service=${service},container=${name},reason=${reason}"
}

check_once() {
  local ids count=0 total avail used_pct free_pct gpu_total gpu_used gpu_pct
  ids="$(running_ids || true)"
  if [[ -z "$ids" ]]; then
    printf 'running=0\n'
    return 3
  fi
  count="$(printf '%s\n' "$ids" | awk 'NF {n++} END {print n+0}')"
  container_memory_check
  read -r total avail <<<"$(host_memory)"
  used_pct="$(percent "$((total-avail))" "$total")"
  free_pct="$(percent "$avail" "$total")"
  printf 'project=%s running=%s host_available_mb=%s host_used_percent=%s\n' "$PROJECT" "$count" "$((avail/1024))" "$used_pct"
  read -r gpu_total gpu_used gpu_free <<<"$(gpu_memory || true)" || true
  if [[ "${gpu_total:-0}" =~ ^[0-9]+$ && "$gpu_total" -gt 0 ]]; then
    gpu_pct="$(percent "$gpu_used" "$gpu_total")"
    printf 'gpu_total_mb=%s gpu_used_mb=%s gpu_free_mb=%s gpu_used_percent=%s\n' "$gpu_total" "$gpu_used" "$gpu_free" "$gpu_pct"
    if (( gpu_pct >= ${AGENTIC_MEMORY_WATCHDOG_GPU_STOP_PERCENT:-95} || gpu_free < ${AGENTIC_MEMORY_WATCHDOG_GPU_RESERVED_MB:-12288} )); then
      stop_victim "gpu-critical-${gpu_used}MiB/${gpu_total}MiB" || true
    fi
  fi
  if (( free_pct <= ${AGENTIC_MEMORY_WATCHDOG_HOST_CRITICAL_PERCENT:-10} )); then
    stop_victim "host-memory-critical-${free_pct}percent" || true
  fi
  return 0
}

status() {
  printf 'enabled=%s project=%s pid_file=%s\n' "${AGENTIC_MEMORY_WATCHDOG_ENABLED:-0}" "$PROJECT" "$PID_FILE"
  if [[ -s "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then printf 'state=running pid=%s\n' "$(cat "$PID_FILE")"; else printf 'state=stopped\n'; fi
  [[ -f "$QUARANTINE_FILE" ]] && { printf 'quarantine:\n'; tail -n 20 "$QUARANTINE_FILE"; }
  check_once || true
}

stop() { [[ -s "$PID_FILE" ]] && kill "$(cat "$PID_FILE")" 2>/dev/null || true; rm -f "$PID_FILE"; log_event "stopped" "requested"; }

daemon() {
  if [[ -s "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then exit 0; fi
  printf '%s\n' "$$" >"$PID_FILE"
  trap 'rm -f "$PID_FILE"' EXIT INT TERM
  local empty_since=0 rc
  log_event "started" "interval=${INTERVAL},dry_run=${DRY_RUN}"
  while :; do
    set +e; check_once; rc=$?; set -e
    if [[ "$rc" == 3 ]]; then
      ((empty_since == 0)) && empty_since="$(date +%s)"
      (( $(date +%s) - empty_since >= EMPTY_GRACE )) && { log_event "exited" "stack-absent"; return 0; }
    else
      empty_since=0
    fi
    sleep "$INTERVAL"
  done
}

case "${1:---daemon}" in
  --daemon) [[ "${AGENTIC_PROFILE:-rootless-dev}" == "rootless-dev" ]] || exit 0; daemon ;;
  --once)
    set +e
    check_once
    rc=$?
    set -e
    [[ "$rc" == 0 || "$rc" == 3 ]] || exit "$rc"
    exit 0
    ;;
  --status) status ;;
  --stop) stop ;;
  *) echo "Usage: memory_watchdog.sh [--daemon|--once|--status|--stop]" >&2; exit 2 ;;
esac
