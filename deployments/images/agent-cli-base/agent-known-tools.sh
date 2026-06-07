#!/bin/sh
set -eu

state_dir="${AGENT_STATE_DIR:-/state}"
tools_md="${state_dir}/bootstrap/known-local-tools.md"

if [ ! -r "${tools_md}" ]; then
  echo "ERROR: known local tools manifest is missing: ${tools_md}" >&2
  exit 1
fi

cat "${tools_md}"
