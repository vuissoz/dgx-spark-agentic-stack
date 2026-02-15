#!/usr/bin/env bash
set -euo pipefail

tool="${AGENT_TOOL:-agent}"
session="${AGENT_SESSION:-${tool}}"
workspace="${AGENT_WORKSPACE:-/workspace}"
state_dir="${AGENT_STATE_DIR:-/state}"
logs_dir="${AGENT_LOGS_DIR:-/logs}"

mkdir -p "${workspace}" "${state_dir}" "${logs_dir}"

start_session() {
  tmux new-session -d -s "${session}" -c "${workspace}" "bash -lc 'exec bash -l'"
}

if ! tmux has-session -t "${session}" 2>/dev/null; then
  start_session
fi

while true; do
  sleep 5
  if ! tmux has-session -t "${session}" 2>/dev/null; then
    start_session
  fi
done
